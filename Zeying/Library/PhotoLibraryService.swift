@preconcurrency import AVFoundation
import Foundation
import Observation
@preconcurrency import Photos
import UIKit
import UniformTypeIdentifiers

/// Errors raised while applying a change to the user's photo library.
enum PhotoLibraryServiceError: LocalizedError {
    case authorizationRequired(PHAuthorizationStatus)
    case changeFailed(String)
    case shareFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired(let status):
            switch status {
            case .notDetermined:
                return String(localized: "需要先获得照片图库权限。")
            case .restricted:
                return String(localized: "系统限制了照片图库访问。")
            case .denied:
                return String(localized: "没有照片图库访问权限。")
            case .limited:
                return String(localized: "只能操作当前获准访问的照片。")
            case .authorized:
                return String(localized: "照片图库权限有效。")
            @unknown default:
                return String(localized: "照片图库权限不可用。")
            }
        case .changeFailed(let message):
            return message
        case .shareFailed(let message):
            return message
        }
    }
}

/// The single PhotoKit entry point used by the review UI.
@MainActor
@Observable
final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    @ObservationIgnored private let photoLibrary = PHPhotoLibrary.shared()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var albumRefreshGeneration = 0
    @ObservationIgnored private var assetFetchResult: PHFetchResult<PHAsset>?
    @ObservationIgnored private var suggestionAssetFingerprint: Int?
    @ObservationIgnored private var previewAssetFingerprint: Int?
    @ObservationIgnored private var assetSnapshotFingerprint: Int?
    @ObservationIgnored private var assetsByIdentifier: [String: PHAsset] = [:]
    @ObservationIgnored private let quickPreviewCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private let reviewPreviewCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var quickPreviewTasks: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var quickPreviewTokens: [String: UUID] = [:]
    @ObservationIgnored private var reviewPreviewTasks: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var reviewPreviewTokens: [String: UUID] = [:]
    @ObservationIgnored private var unavailableLocalReviewIDs: Set<String> = []
    @ObservationIgnored private var networkPreviewTasks: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var networkPreviewTokens: [String: UUID] = [:]
    @ObservationIgnored private var localVideoItemTasks: [String: Task<AVPlayerItem?, Never>] = [:]

    private(set) var authorizationStatus: PHAuthorizationStatus
    private(set) var assets: [PHAsset] = []
    private(set) var albums: [LibraryAlbum] = []
    private(set) var revision = 0
    private(set) var assetRevision = 0
    private(set) var suggestionRevision = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        // NSCache may evict earlier under memory pressure. These limits keep
        // several upcoming Live Photo still frames ready without retaining motion.
        quickPreviewCache.countLimit = 18
        quickPreviewCache.totalCostLimit = 80 * 1_024 * 1_024
        reviewPreviewCache.countLimit = 10
        reviewPreviewCache.totalCostLimit = 112 * 1_024 * 1_024
        photoLibrary.register(self)

        if Self.canRead(authorizationStatus) {
            scheduleRefresh()
        }
    }

    deinit {
        photoLibrary.unregisterChangeObserver(self)
    }

    /// Requests read/write access and refreshes the in-memory library snapshot.
    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status

        if Self.canRead(status) {
            await refresh()
        } else {
            clearSnapshot()
        }
    }

    /// Rebuilds the current asset and album snapshots from PhotoKit.
    func refresh() async {
        await startRefresh().value
    }

    /// Waits for the first complete snapshot without scanning the library
    /// again whenever a review screen opens.
    func ensureLoaded() async {
        while !hasLoaded, !Task.isCancelled {
            let task = refreshTask ?? startRefresh()
            await task.value
            guard Self.canRead(authorizationStatus) else { return }
        }
    }

    private func startRefresh() -> Task<Void, Never> {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        albumRefreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        let task = Task { @MainActor [weak self] in
            await self?.performRefresh(generation: generation)
            guard let self, self.refreshGeneration == generation else { return }
            self.isLoading = false
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    private func performRefresh(generation: Int) async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        guard Self.canRead(authorizationStatus) else {
            clearSnapshot()
            return
        }
        guard !Task.isCancelled else { return }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetchedResult = PHAsset.fetchAssets(with: options)
        let refreshedAssets = await fetchAllAssets(from: fetchedResult)
        guard !Task.isCancelled, generation == refreshGeneration else { return }

        let refreshedAlbums = await fetchAlbums(authorizedAssets: refreshedAssets)
        let finalStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = finalStatus
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        guard Self.canRead(finalStatus) else {
            clearSnapshot()
            return
        }
        assetFetchResult = fetchedResult
        // Album membership changes do not change image pixels. Keep the
        // review cache and its in-flight requests when PhotoKit reports one.
        var previewFingerprint = Hasher()
        var snapshotFingerprint = Hasher()
        var suggestionFingerprint = Hasher()
        for asset in refreshedAssets {
            previewFingerprint.combine(asset.localIdentifier)
            previewFingerprint.combine(asset.mediaType.rawValue)
            previewFingerprint.combine(asset.modificationDate)
            previewFingerprint.combine(asset.pixelWidth)
            previewFingerprint.combine(asset.pixelHeight)
            previewFingerprint.combine(asset.mediaSubtypes.rawValue)
            snapshotFingerprint.combine(asset.localIdentifier)
            snapshotFingerprint.combine(asset.mediaType.rawValue)
            snapshotFingerprint.combine(asset.creationDate)
            snapshotFingerprint.combine(asset.modificationDate)
            snapshotFingerprint.combine(asset.pixelWidth)
            snapshotFingerprint.combine(asset.pixelHeight)
            snapshotFingerprint.combine(asset.mediaSubtypes.rawValue)
            snapshotFingerprint.combine(asset.isFavorite)
            snapshotFingerprint.combine(asset.burstIdentifier)
            if asset.mediaType == .image {
                suggestionFingerprint.combine(asset.localIdentifier)
                suggestionFingerprint.combine(asset.creationDate)
                suggestionFingerprint.combine(asset.modificationDate)
                suggestionFingerprint.combine(asset.pixelWidth)
                suggestionFingerprint.combine(asset.pixelHeight)
                suggestionFingerprint.combine(asset.mediaSubtypes.rawValue)
                suggestionFingerprint.combine(asset.isFavorite)
                suggestionFingerprint.combine(asset.burstIdentifier)
            }
        }
        let newPreviewFingerprint = previewFingerprint.finalize()
        if previewAssetFingerprint != newPreviewFingerprint {
            previewAssetFingerprint = newPreviewFingerprint
            stopReviewPrefetching()
            quickPreviewCache.removeAllObjects()
            reviewPreviewCache.removeAllObjects()
            unavailableLocalReviewIDs.removeAll()
        }
        let newSnapshotFingerprint = snapshotFingerprint.finalize()
        if assetSnapshotFingerprint != newSnapshotFingerprint {
            assetSnapshotFingerprint = newSnapshotFingerprint
            assetRevision &+= 1
            assets = refreshedAssets
            assetsByIdentifier = Dictionary(
                uniqueKeysWithValues: refreshedAssets.map { ($0.localIdentifier, $0) }
            )
        }
        let newSuggestionFingerprint = suggestionFingerprint.finalize()
        if suggestionAssetFingerprint != newSuggestionFingerprint {
            suggestionAssetFingerprint = newSuggestionFingerprint
            suggestionRevision &+= 1
        }
        albums = refreshedAlbums
        hasLoaded = true
        revision += 1
    }

    /// Returns assets matching a library scope. `.later` is intentionally left
    /// to the UI, which has access to ReviewStore's persisted decisions.
    func assets(in scope: LibraryScope) -> [PHAsset] {
        switch scope {
        case .all:
            return assets
        case .random:
            return assets
        case .month(let date):
            return assets(inMonthContaining: date)
        case .year(let date):
            return assets(inYearContaining: date)
        case .album(let identifier):
            return assets(inAlbumWithIdentifier: identifier)
        case .category(let category):
            return assets(inCategory: category)
        case .later:
            // ReviewStore owns the persisted `.later` decision. Returning an
            // empty scope keeps that filtering explicit at the UI boundary.
            return []
        }
    }

    /// Looks up an asset that is currently accessible to the app.
    func asset(with identifier: String) -> PHAsset? {
        guard Self.canRead(authorizationStatus) else { return nil }
        if let snapshotAsset = assetsByIdentifier[identifier] {
            return snapshotAsset
        }

        // Once a complete snapshot exists, an absent identifier is currently
        // inaccessible. Avoid one synchronous PhotoKit fetch per missing row.
        guard !hasLoaded else { return nil }

        return PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier],
            options: nil
        ).firstObject
    }

    /// Prepares the selected photo or video as a temporary file for the native
    /// share sheet. This runs only after the user taps Share; iCloud data may
    /// be downloaded as part of that explicit action.
    func exportForSharing(_ asset: PHAsset) async throws -> URL {
        let preferredTypes: [PHAssetResourceType] = asset.mediaType == .video
            ? [.video, .fullSizeVideo]
            : [.photo, .fullSizePhoto]
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = preferredTypes.compactMap({ preferred in
            resources.first(where: { $0.type == preferred })
        }).first else {
            throw PhotoLibraryServiceError.shareFailed(String(localized: "无法找到这张照片或视频的可分享文件。"))
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeyingShare", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileExtension = resource.contentType.preferredFilenameExtension
            ?? (asset.mediaType == .video ? "mov" : "jpg")
        let fileURL = folder.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: fileURL,
                    options: options
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            return fileURL
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw PhotoLibraryServiceError.shareFailed(PhotosFailureMessage.message(for: error))
        }
    }

    /// Requests an image without downloading an iCloud original by default.
    /// Callers that are showing the full review preview can opt in to network
    /// access explicitly; list and album thumbnails should keep the default.
    func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        allowNetwork: Bool = false,
        contentMode: PHImageContentMode = .aspectFit,
        onDegraded: (@MainActor (UIImage) -> Void)? = nil,
        deliveryMode: PHImageRequestOptionsDeliveryMode? = nil
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }

        let options = PHImageRequestOptions()
        // Opportunistic thumbnails may settle early; review-quality requests
        // wait for a final local rendition or an explicit cloud-only result.
        options.deliveryMode = deliveryMode ?? (allowNetwork ? .highQualityFormat : .opportunistic)
        options.resizeMode = options.deliveryMode == .highQualityFormat ? .exact : .fast
        options.isNetworkAccessAllowed = allowNetwork

        let manager = PHImageManager.default()
        let request = OneShotContinuation<UIImage?>(cancellationValue: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: contentMode,
                    options: options
                ) { image, info in
                    let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    let hasError = info?[PHImageErrorKey] != nil
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    let isOnlyInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false

                    if isCancelled || hasError || (!allowNetwork && isOnlyInCloud && deliveryMode == .highQualityFormat) {
                        request.resume(returning: nil)
                    } else if isDegraded {
                        if let image {
                            if let onDegraded {
                                Task { @MainActor in onDegraded(image) }
                            }
                            let waitsForFinal = options.deliveryMode == .highQualityFormat
                            if !waitsForFinal {
                                request.finishEarly(returning: image, using: manager)
                            }
                        } else if !allowNetwork {
                            // PhotoKit may report a degraded, cloud-only
                            // result without pixels. Finish with a visible
                            // missing-preview state instead of leaking the
                            // continuation while waiting for an impossible
                            // local callback. A network-enabled request must
                            // keep waiting for its download's final result.
                            request.resume(returning: nil)
                        }
                    } else if !isDegraded {
                        request.resume(returning: image)
                    }
                }
                request.install(requestID: requestID, manager: manager)
            }
        } onCancel: {
            request.cancel(using: manager)
        }
    }

    /// Keeps a few nearby cards ready without fetching iCloud originals.
    func cachedQuickPreview(for asset: PHAsset) -> UIImage? {
        quickPreviewCache.object(forKey: asset.localIdentifier as NSString)
    }

    func cachedReviewPreview(for asset: PHAsset) -> UIImage? {
        reviewPreviewCache.object(forKey: asset.localIdentifier as NSString)
    }

    func cacheReviewPreview(_ image: UIImage, for asset: PHAsset) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        reviewPreviewCache.setObject(image, forKey: asset.localIdentifier as NSString, cost: cost)
    }

    /// Keep the nearest cards ready without flooding PhotoKit with concurrent
    /// full-resolution requests. A quick rendition prevents an empty handoff
    /// if the review-quality request has not completed yet.
    /// Cloud-only originals are not downloaded ahead of the user's decision.
    func prefetchReviewPreviews(_ upcoming: [PHAsset], keeping currentIdentifier: String) {
        let candidates = Array(upcoming.prefix(5))
        let nextVideo = candidates.prefix(2).first { $0.mediaType == .video }
        let neededReview = Set([currentIdentifier] + candidates.prefix(2).map(\.localIdentifier))
        let neededQuick = Set([currentIdentifier] + candidates.map(\.localIdentifier))
        let neededVideo = Set([currentIdentifier] + [nextVideo?.localIdentifier].compactMap { $0 })
        for identifier in reviewPreviewTasks.keys.filter({ !neededReview.contains($0) }) {
            reviewPreviewTasks[identifier]?.cancel()
            reviewPreviewTasks.removeValue(forKey: identifier)
            reviewPreviewTokens.removeValue(forKey: identifier)
        }
        for identifier in quickPreviewTasks.keys.filter({ !neededQuick.contains($0) }) {
            quickPreviewTasks[identifier]?.cancel()
            quickPreviewTasks.removeValue(forKey: identifier)
            quickPreviewTokens.removeValue(forKey: identifier)
        }
        for identifier in localVideoItemTasks.keys.filter({ !neededVideo.contains($0) }) {
            localVideoItemTasks[identifier]?.cancel()
            localVideoItemTasks.removeValue(forKey: identifier)
        }
        // Prefetch owns no network work. Cancel any older opt-in network
        // tasks when the queue advances so an earlier screen cannot keep
        // pulling cloud originals in the background.
        for identifier in Array(networkPreviewTasks.keys) {
            networkPreviewTasks[identifier]?.cancel()
            networkPreviewTasks.removeValue(forKey: identifier)
            networkPreviewTokens.removeValue(forKey: identifier)
        }

        for asset in candidates.prefix(3)
        where cachedQuickPreview(for: asset) == nil && cachedReviewPreview(for: asset) == nil {
            _ = quickPreviewTask(for: asset)
        }
        // Decode only the two nearest full-size cards. Five simultaneous
        // 1,500-pixel requests compete with the card being revealed and can
        // cause a blank frame as well as unnecessary CPU and energy use.
        for asset in candidates.prefix(2) where asset.mediaType != .video {
            if cachedReviewPreview(for: asset) == nil,
               !unavailableLocalReviewIDs.contains(asset.localIdentifier) {
                _ = reviewPreviewTask(for: asset)
            }
        }
        // One nearby local player item is enough to hide PhotoKit startup
        // without downloading an iCloud video or retaining a video queue.
        if let nextVideo, localVideoItemTasks[nextVideo.localIdentifier] == nil {
            localVideoItemTasks[nextVideo.localIdentifier] = Task(priority: .utility) { @MainActor [weak self] in
                await self?.requestPlayerItemDirect(for: nextVideo, allowNetwork: false)
            }
        }
    }

    func prepareReviewPreview(for asset: PHAsset, allowNetwork: Bool = false) async -> UIImage? {
        // A video needs only a poster while PhotoKit prepares its player item.
        // Waiting for a separate high-quality still can delay the whole review
        // queue and compete with video startup for decoding resources.
        if asset.mediaType == .video { return await quickPreview(for: asset) }
        if let cached = cachedReviewPreview(for: asset) { return cached }
        if !unavailableLocalReviewIDs.contains(asset.localIdentifier),
           let localImage = await reviewPreviewTask(for: asset).value { return localImage }
        guard allowNetwork, !Task.isCancelled else { return nil }
        let image = await requestImage(
            for: asset,
            targetSize: CGSize(width: 1_500, height: 1_500),
            allowNetwork: true,
            deliveryMode: .highQualityFormat
        )
        if let image, !Task.isCancelled { cacheReviewPreview(image, for: asset) }
        return image
    }

    private func reviewPreviewTask(for asset: PHAsset) -> Task<UIImage?, Never> {
        let identifier = asset.localIdentifier
        if let existing = reviewPreviewTasks[identifier] { return existing }
        let token = UUID()
        reviewPreviewTokens[identifier] = token
        let task = Task(priority: .utility) { @MainActor [weak self] () -> UIImage? in
            guard let self else { return nil }
            defer {
                if self.reviewPreviewTokens[identifier] == token {
                    self.reviewPreviewTasks.removeValue(forKey: identifier)
                    self.reviewPreviewTokens.removeValue(forKey: identifier)
                }
            }
            let image = await self.requestImage(
                for: asset,
                targetSize: CGSize(width: 1_500, height: 1_500),
                allowNetwork: false,
                deliveryMode: .highQualityFormat
            )
            if !Task.isCancelled {
                if let image {
                    self.cacheReviewPreview(image, for: asset)
                } else {
                    self.unavailableLocalReviewIDs.insert(identifier)
                }
            }
            return image
        }
        reviewPreviewTasks[identifier] = task
        return task
    }

    func stopReviewPrefetching() {
        for task in reviewPreviewTasks.values { task.cancel() }
        reviewPreviewTasks.removeAll()
        reviewPreviewTokens.removeAll()
        for task in quickPreviewTasks.values { task.cancel() }
        quickPreviewTasks.removeAll()
        quickPreviewTokens.removeAll()
        for task in networkPreviewTasks.values { task.cancel() }
        networkPreviewTasks.removeAll()
        networkPreviewTokens.removeAll()
        for task in localVideoItemTasks.values { task.cancel() }
        localVideoItemTasks.removeAll()
    }

    /// Returns the first useful local rendition without waiting for final
    /// quality. Network access is an explicit opt-in for callers such as a
    /// user-requested zoom, never a prefetch default.
    func quickPreview(for asset: PHAsset, allowNetwork: Bool = false) async -> UIImage? {
        if let cached = cachedQuickPreview(for: asset) { return cached }
        if let cached = cachedReviewPreview(for: asset) { return cached }
        let localTask = quickPreviewTask(for: asset)
        if let localImage = await awaitPreview(localTask) { return localImage }
        guard allowNetwork, asset.mediaType == .image, !Task.isCancelled else { return nil }
        if let cached = cachedReviewPreview(for: asset) { return cached }
        return await awaitPreview(networkPreviewTask(for: asset))
    }

    /// Asks PhotoKit for a display-sized rendition only for the viewed image.
    /// PhotoKit may use network data to produce it; the separate setting
    /// controls whether we request a high-quality preview afterwards.
    func cloudThumbnail(for asset: PHAsset) async -> UIImage? {
        guard asset.mediaType == .image, !Task.isCancelled else { return nil }
        if let cached = cachedQuickPreview(for: asset) ?? cachedReviewPreview(for: asset) {
            return cached
        }

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        let request = OneShotContinuation<UIImage?>(cancellationValue: nil)
        let thumbnail = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 640, height: 640),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                        request.resume(returning: nil)
                    } else if let image {
                        request.finishEarly(returning: image, using: manager)
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) != true {
                        request.resume(returning: nil)
                    }
                }
                request.install(requestID: requestID, manager: manager)
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    request.cancel(using: manager)
                }
            }
        } onCancel: {
            request.cancel(using: manager)
        }
        if let thumbnail, !Task.isCancelled { cacheQuickPreview(thumbnail, for: asset) }
        return thumbnail
    }

    private func cacheQuickPreview(_ image: UIImage, for asset: PHAsset) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        quickPreviewCache.setObject(image, forKey: asset.localIdentifier as NSString, cost: cost)
    }

    private func awaitPreview(_ task: Task<UIImage?, Never>) async -> UIImage? {
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            // `Task.value` does not propagate cancellation to an unstructured
            // task. Forward it so a disappearing card also cancels the
            // underlying PhotoKit request instead of retaining its
            // continuation until PhotoKit eventually responds.
            task.cancel()
        })
    }

    private func quickPreviewTask(for asset: PHAsset) -> Task<UIImage?, Never> {
        let identifier = asset.localIdentifier
        if let existing = quickPreviewTasks[identifier] { return existing }
        let token = UUID()
        quickPreviewTokens[identifier] = token
        let task = Task(priority: .utility) { @MainActor [weak self] () -> UIImage? in
            guard let self else { return nil }
            defer {
                if self.quickPreviewTokens[identifier] == token {
                    self.quickPreviewTasks.removeValue(forKey: identifier)
                    self.quickPreviewTokens.removeValue(forKey: identifier)
                }
            }
            let image = await self.requestImage(
                for: asset,
                targetSize: CGSize(width: 1_500, height: 1_500),
                allowNetwork: false,
                contentMode: .aspectFit,
                deliveryMode: .opportunistic
            )
            guard !Task.isCancelled, let image else { return nil }
            self.cacheQuickPreview(image, for: asset)
            return image
        }
        quickPreviewTasks[identifier] = task
        return task
    }

    private func networkPreviewTask(for asset: PHAsset) -> Task<UIImage?, Never> {
        let identifier = asset.localIdentifier
        if let existing = networkPreviewTasks[identifier] { return existing }
        let token = UUID()
        networkPreviewTokens[identifier] = token
        let task = Task(priority: .utility) { @MainActor [weak self] () -> UIImage? in
            guard let self else { return nil }
            defer {
                if self.networkPreviewTokens[identifier] == token {
                    self.networkPreviewTasks.removeValue(forKey: identifier)
                    self.networkPreviewTokens.removeValue(forKey: identifier)
                }
            }
            if let cached = self.cachedReviewPreview(for: asset)
                ?? self.cachedQuickPreview(for: asset) {
                return cached
            }
            if let localImage = await self.awaitPreview(self.quickPreviewTask(for: asset)) {
                return localImage
            }
            guard !Task.isCancelled else { return nil }
            let image = await self.requestImage(
                for: asset,
                targetSize: CGSize(width: 1_500, height: 1_500),
                allowNetwork: true,
                contentMode: .aspectFit,
                deliveryMode: .highQualityFormat
            )
            guard !Task.isCancelled, let image else { return nil }
            self.cacheQuickPreview(image, for: asset)
            self.cacheReviewPreview(image, for: asset)
            return image
        }
        networkPreviewTasks[identifier] = task
        return task
    }

    /// Loads the motion component only after the user long-presses a Live
    /// Photo. Network access is opt-in for that explicit gesture.
    func requestLivePhoto(for asset: PHAsset, allowNetwork: Bool = false) async -> PHLivePhoto? {
        guard !Task.isCancelled, asset.mediaSubtypes.contains(.photoLive) else { return nil }

        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowNetwork

        let manager = PHImageManager.default()
        let request = OneShotContinuation<PHLivePhoto?>(cancellationValue: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = manager.requestLivePhoto(
                    for: asset,
                    targetSize: CGSize(width: 1_200, height: 1_200),
                    contentMode: .aspectFit,
                    options: options
                ) { livePhoto, info in
                    let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    let hasError = info?[PHImageErrorKey] != nil
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if isCancelled || hasError {
                        request.resume(returning: nil)
                    } else if !isDegraded {
                        request.resume(returning: livePhoto)
                    }
                }
                request.install(requestID: requestID, manager: manager)
            }
        } onCancel: {
            request.cancel(using: manager)
        }
    }

    /// Requests an AVPlayerItem for a video asset. Review autoplay uses only
    /// local resources; opening a cloud-only video requires an explicit tap.
    func requestPlayerItem(for asset: PHAsset, allowNetwork: Bool = false) async -> AVPlayerItem? {
        guard !Task.isCancelled else { return nil }
        if !allowNetwork, let prefetched = localVideoItemTasks.removeValue(forKey: asset.localIdentifier) {
            return await withTaskCancellationHandler {
                await prefetched.value
            } onCancel: {
                prefetched.cancel()
            }
        }
        return await requestPlayerItemDirect(for: asset, allowNetwork: allowNetwork)
    }

    private func requestPlayerItemDirect(for asset: PHAsset, allowNetwork: Bool) async -> AVPlayerItem? {
        // PhotoKit may synchronously prepare video metadata before returning
        // a request ID. Keep that work away from the review buttons and swipes.
        await VideoPreviewLoader.load(identifier: asset.localIdentifier, allowNetwork: allowNetwork)
    }

    /// Marks accessible, non-favorited assets as favorites in one PhotoKit
    /// transaction and returns the identifiers that reached the favorited
    /// state, including assets already favorited by another app.
    @discardableResult
    func favorite(_ identifiers: [String]) async throws -> [String] {
        try requireReadWriteAccess()

        let accessibleAssets = availableAssets(for: identifiers)
        let candidates = accessibleAssets.filter { !$0.isFavorite }
        // An already-favorited asset has reached the requested end state even
        // if another app made that change. Returning it lets ReviewStore clear
        // its pending local favorite marker.
        let completedIdentifiers = accessibleAssets.map(\.localIdentifier)
        guard !candidates.isEmpty else {
            if completedIdentifiers.isEmpty, !identifiers.isEmpty { await refresh() }
            return completedIdentifiers
        }

        do {
            try await photoLibrary.performChanges {
                for asset in candidates {
                    PHAssetChangeRequest(for: asset).isFavorite = true
                }
            }
        } catch {
            throw PhotoLibraryServiceError.changeFailed(PhotosFailureMessage.message(for: error))
        }

        await refresh()
        return completedIdentifiers
    }

    /// Clears the system favorite flag without changing the review decision.
    func unfavorite(_ identifier: String) async throws {
        try requireReadWriteAccess()
        guard let asset = availableAssets(for: [identifier]).first else {
            throw PhotoLibraryServiceError.changeFailed(
                String(localized: "这张照片已无法访问，未取消收藏。")
            )
        }
        if asset.isFavorite {
            do {
                try await photoLibrary.performChanges {
                    PHAssetChangeRequest(for: asset).isFavorite = false
                }
            } catch {
                throw PhotoLibraryServiceError.changeFailed(PhotosFailureMessage.message(for: error))
            }
        }
        let isConfirmed = availableAssets(for: [identifier]).first.map { !$0.isFavorite } ?? false
        await refresh()
        guard isConfirmed else {
            throw PhotoLibraryServiceError.changeFailed(
                String(localized: "尚未确认已取消收藏，请在系统照片中检查。")
            )
        }
    }

    /// Deletes accessible assets in one PhotoKit transaction and returns the
    /// identifiers accepted by that transaction.
    @discardableResult
    func delete(_ identifiers: [String]) async throws -> [String] {
        try requireReadWriteAccess()

        let candidates = availableAssets(for: identifiers)
        let deletedIdentifiers = candidates.map(\.localIdentifier)
        guard !candidates.isEmpty else {
            if !identifiers.isEmpty { await refresh() }
            return []
        }

        do {
            try await photoLibrary.performChanges {
                PHAssetChangeRequest.deleteAssets(candidates as NSArray)
            }
        } catch {
            // Preserve cancellation codes for the confirmation UI.
            throw error
        }

        await refresh()
        return deletedIdentifiers
    }

    // MARK: - PHPhotoLibraryChangeObserver

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) != self.authorizationStatus {
                await self.refresh()
            } else if let assetFetchResult = self.assetFetchResult,
               changeInstance.changeDetails(for: assetFetchResult) == nil {
                await self.refreshAlbumsOnly()
            } else {
                await self.refresh()
            }
        }
    }

    private func refreshAlbumsOnly() async {
        albumRefreshGeneration &+= 1
        let generation = albumRefreshGeneration
        let refreshedAlbums = await fetchAlbums(authorizedAssets: assets, albumGeneration: generation)
        guard !Task.isCancelled, generation == albumRefreshGeneration else { return }
        albums = refreshedAlbums
        revision &+= 1
    }

    // MARK: - Fetching

    private func fetchAllAssets(from result: PHFetchResult<PHAsset>) async -> [PHAsset] {
        var fetchedAssets: [PHAsset] = []
        fetchedAssets.reserveCapacity(result.count)
        for index in 0..<result.count {
            guard !Task.isCancelled else { return [] }
            fetchedAssets.append(result.object(at: index))
            if index.isMultiple(of: 256) {
                await Task.yield()
                guard !Task.isCancelled else { return [] }
            }
        }
        return fetchedAssets
    }

    private func fetchAlbums(
        authorizedAssets: [PHAsset], albumGeneration: Int? = nil
    ) async -> [LibraryAlbum] {
        func isSuperseded() -> Bool {
            albumGeneration.map { $0 != albumRefreshGeneration } ?? false
        }
        let authorizedIdentifiers = Set(authorizedAssets.map(\.localIdentifier))
        var collections: [PHAssetCollection] = []

        for (type, subtype) in [
            (PHAssetCollectionType.album, PHAssetCollectionSubtype.any),
            (PHAssetCollectionType.smartAlbum, PHAssetCollectionSubtype.any)
        ] {
            let result = PHAssetCollection.fetchAssetCollections(with: type, subtype: subtype, options: nil)
            for index in 0..<result.count {
                guard !Task.isCancelled, !isSuperseded() else { return [] }
                collections.append(result.object(at: index))
                if index.isMultiple(of: 32) {
                    await Task.yield()
                    guard !Task.isCancelled, !isSuperseded() else { return [] }
                }
            }
        }

        var result: [LibraryAlbum] = []
        result.reserveCapacity(collections.count)

        for (collectionIndex, collection) in collections.enumerated() where shouldInclude(collection) {
            guard !Task.isCancelled, !isSuperseded() else { return [] }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let collectionAssets = PHAsset.fetchAssets(in: collection, options: options)

            var count = 0
            var coverIdentifier: String?
            for assetIndex in 0..<collectionAssets.count {
                guard !Task.isCancelled, !isSuperseded() else { return [] }
                let asset = collectionAssets.object(at: assetIndex)
                guard authorizedIdentifiers.contains(asset.localIdentifier) else {
                    if assetIndex.isMultiple(of: 256) { await Task.yield() }
                    continue
                }
                count += 1
                if coverIdentifier == nil {
                    coverIdentifier = asset.localIdentifier
                }
                if assetIndex.isMultiple(of: 256) { await Task.yield() }
                if assetIndex.isMultiple(of: 256), Task.isCancelled || isSuperseded() { return [] }
            }

            guard count > 0 else { continue }
            let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                LibraryAlbum(
                    id: collection.localIdentifier,
                    title: title?.isEmpty == false ? title! : String(localized: "未命名相簿"),
                    count: count,
                    coverAssetIdentifier: coverIdentifier,
                    smartSubtypeRawValue: collection.assetCollectionType == .smartAlbum
                        ? collection.assetCollectionSubtype.rawValue : nil
                )
            )
            if collectionIndex.isMultiple(of: 8) {
                await Task.yield()
                guard !Task.isCancelled, !isSuperseded() else { return [] }
            }
        }

        return result.sorted {
            let lhs = $0.title.localizedStandardCompare($1.title)
            if lhs == .orderedSame { return $0.id < $1.id }
            return lhs == .orderedAscending
        }
    }

    private func shouldInclude(_ collection: PHAssetCollection) -> Bool {
        guard collection.assetCollectionType == .smartAlbum else { return true }
        switch collection.assetCollectionSubtype {
        case .smartAlbumAllHidden:
            return false
        default:
            return true
        }
    }

    private func assets(inMonthContaining date: Date) -> [PHAsset] {
        let calendar = Calendar.autoupdatingCurrent
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        return assets.filter { asset in
            guard let creationDate = asset.creationDate else { return false }
            return interval.contains(creationDate)
        }
    }

    private func assets(inYearContaining date: Date) -> [PHAsset] {
        let calendar = Calendar.autoupdatingCurrent
        guard let interval = calendar.dateInterval(of: .year, for: date) else { return [] }
        return assets.filter { asset in
            guard let creationDate = asset.creationDate else { return false }
            return interval.contains(creationDate)
        }
    }

    private func assets(inAlbumWithIdentifier identifier: String) -> [PHAsset] {
        guard Self.canRead(authorizationStatus),
              let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier],
                options: nil
              ).firstObject else {
            return []
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(in: collection, options: options)
        let snapshotIdentifiers = Set(assets.map(\.localIdentifier))

        var result: [PHAsset] = []
        result.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            // An empty snapshot can occur during the initial async refresh. In
            // that case PhotoKit has already applied the current authorization.
            if snapshotIdentifiers.isEmpty || snapshotIdentifiers.contains(asset.localIdentifier) {
                result.append(asset)
            }
        }
        return result
    }

    private func assets(inCategory category: MediaCategory) -> [PHAsset] {
        switch category {
        case .photo:
            return assets.filter { $0.mediaType == .image }
        case .video:
            return assets.filter { $0.mediaType == .video }
        case .screenshot:
            return assets.filter { $0.mediaSubtypes.contains(.photoScreenshot) }
        case .livePhoto:
            return assets.filter { $0.mediaSubtypes.contains(.photoLive) }
        case .screenRecording:
            return assets.filter { $0.mediaSubtypes.contains(.videoScreenRecording) }
        case .selfie:
            return assets(inSmartAlbumSubtype: .smartAlbumSelfPortraits)
        }
    }

    private func assets(inSmartAlbumSubtype subtype: PHAssetCollectionSubtype) -> [PHAsset] {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: subtype,
            options: nil
        ).firstObject else {
            return []
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(in: collection, options: options)
        let snapshotIdentifiers = Set(assets.map(\.localIdentifier))

        var result: [PHAsset] = []
        result.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            if snapshotIdentifiers.contains(asset.localIdentifier) {
                result.append(asset)
            }
        }
        return result
    }

    private func availableAssets(for identifiers: [String]) -> [PHAsset] {
        var uniqueIdentifiers: [String] = []
        var seen: Set<String> = []
        uniqueIdentifiers.reserveCapacity(identifiers.count)
        for identifier in identifiers where !identifier.isEmpty && seen.insert(identifier).inserted {
            uniqueIdentifiers.append(identifier)
        }
        guard !uniqueIdentifiers.isEmpty else { return [] }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIdentifiers, options: nil)
        var byIdentifier: [String: PHAsset] = [:]
        byIdentifier.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            byIdentifier[asset.localIdentifier] = asset
        }
        return uniqueIdentifiers.compactMap { byIdentifier[$0] }
    }

    private func requireReadWriteAccess() throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = currentStatus
        guard Self.canRead(currentStatus) else {
            throw PhotoLibraryServiceError.authorizationRequired(currentStatus)
        }
    }

    private func scheduleRefresh() {
        _ = startRefresh()
    }

    private func clearSnapshot() {
        assetFetchResult = nil
        previewAssetFingerprint = nil
        assetSnapshotFingerprint = nil
        suggestionAssetFingerprint = nil
        assetRevision &+= 1
        stopReviewPrefetching()
        quickPreviewCache.removeAllObjects()
        reviewPreviewCache.removeAllObjects()
        unavailableLocalReviewIDs.removeAll()
        assets.removeAll(keepingCapacity: true)
        assetsByIdentifier.removeAll(keepingCapacity: true)
        albums.removeAll(keepingCapacity: true)
        hasLoaded = false
        revision += 1
    }

    private static func canRead(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }
}

private enum VideoPreviewLoader {
    @concurrent
    static func load(identifier: String, allowNetwork: Bool) async -> AVPlayerItem? {
        guard !Task.isCancelled,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              !Task.isCancelled else { return nil }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.version = .current
        options.isNetworkAccessAllowed = allowNetwork
        let manager = PHImageManager.default()
        let request = OneShotContinuation<AVPlayerItem?>(cancellationValue: nil)
        // Local autoplay is opportunistic. A slow original should leave a
        // poster and a manual play button instead of an indefinite spinner.
        let timeout: Task<Void, Never>? = allowNetwork ? nil : Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            request.finishEarly(returning: nil, using: manager)
        }
        defer { timeout?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    request.resume(returning: cancelled || info?[PHImageErrorKey] != nil ? nil : item)
                }
                request.install(requestID: requestID, manager: manager)
            }
        } onCancel: {
            request.cancel(using: manager)
        }
    }
}

final class OneShotContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var requestID: PHImageRequestID?
    private var isFinished = false
    private let cancellationValue: Value

    init(cancellationValue: Value) {
        self.cancellationValue = cancellationValue
    }

    func install(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(returning: cancellationValue)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel {
            manager.cancelImageRequest(requestID)
        }
    }

    func resume(returning value: Value) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func finishEarly(returning value: Value, using manager: PHImageManager) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let requestID = self.requestID
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
        if let requestID {
            manager.cancelImageRequest(requestID)
        }
    }

    func cancel(using manager: PHImageManager) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let requestID = self.requestID
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let requestID {
            manager.cancelImageRequest(requestID)
        }
        continuation?.resume(returning: cancellationValue)
    }
}
