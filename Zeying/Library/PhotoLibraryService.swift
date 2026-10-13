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
    @ObservationIgnored private var snapshot: PhotoLibrarySnapshot?
    @ObservationIgnored private var pendingChanges: [PHChange] = []
    @ObservationIgnored private var changeRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionAssetFingerprint: Int?
    @ObservationIgnored private var assetSnapshotFingerprint: Int?
    @ObservationIgnored private var assetsByIdentifier: [String: PHAsset] = [:]
    @ObservationIgnored private let quickPreviewCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private let reviewPreviewCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var quickPreviewTasks: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var quickPreviewTokens: [String: UUID] = [:]
    @ObservationIgnored private var reviewPreviewTasks: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var reviewPreviewTokens: [String: UUID] = [:]
    @ObservationIgnored private var unavailableLocalReviewIDs: Set<String> = []
    @ObservationIgnored private var cloudAssetIdentifiers: Set<String> = []
    @ObservationIgnored private var networkPreviewTasks: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var networkPreviewTokens: [String: UUID] = [:]
    @ObservationIgnored private var localVideoItemTasks: [String: Task<AVPlayerItem?, Never>] = [:]
    @ObservationIgnored private var memoryPressureUntil = Date.distantPast
    @ObservationIgnored private var memoryRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var lastPrefetchCandidates: [PHAsset] = []
    @ObservationIgnored private var lastPrefetchCurrentIdentifier: String?

    private(set) var authorizationStatus: PHAuthorizationStatus
    private(set) var assets: [PHAsset] = []
    private(set) var albums: [LibraryAlbum] = []
    private(set) var monthBuckets: [LibraryTimeBucket] = []
    private(set) var yearBuckets: [LibraryTimeBucket] = []
    private(set) var suggestionAssets: [SuggestionAsset] = []
    private(set) var scopedAssets: [LibraryScope: [PHAsset]] = [:]
    private(set) var prefetchRevision = 0
    private(set) var revision = 0
    private(set) var assetRevision = 0
    private(set) var albumMembershipRevision = 0
    private(set) var suggestionRevision = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        _ = ProcessInfo.processInfo.thermalState
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

    private func startRefresh(changes: [PHChange] = []) -> Task<Void, Never> {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isLoading = true
        let task = Task { @MainActor [weak self] in
            await self?.performRefresh(generation: generation, changes: changes)
            guard let self, self.refreshGeneration == generation else { return }
            self.isLoading = false
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    private func performRefresh(generation: Int, changes: [PHChange]) async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.canRead(authorizationStatus) else { clearSnapshot(); return }
        guard let refreshed = await PhotoLibrarySnapshotLoader.load(previous: snapshot, changes: changes),
              !Task.isCancelled, generation == refreshGeneration else { return }
        let finalStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = finalStatus
        guard Self.canRead(finalStatus) else { clearSnapshot(); return }
        guard finalStatus == refreshed.authorization else { scheduleRefresh(); return }
        // Only changed pixels invalidate previews. Album/favorite changes
        // leave the current card and unrelated in-flight requests intact.
        if let previous = snapshot {
            for (id, version) in previous.previewVersions where refreshed.previewVersions[id] != version {
                invalidatePreview(identifier: id)
            }
        }
        let assetsChanged = assetSnapshotFingerprint != refreshed.snapshotFingerprint
        let membershipsChanged = snapshot?.albumMembers != refreshed.albumMembers
        if assetsChanged {
            assetSnapshotFingerprint = refreshed.snapshotFingerprint
            assetRevision &+= 1
            assets = refreshed.assets
            assetsByIdentifier = refreshed.assetsByIdentifier
            monthBuckets = refreshed.months
            yearBuckets = refreshed.years
            suggestionAssets = refreshed.suggestionAssets
        }
        if assetsChanged || membershipsChanged {
            scopedAssets = refreshed.scopedAssets
            albumMembershipRevision &+= 1
        }
        if suggestionAssetFingerprint != refreshed.suggestionFingerprint {
            suggestionAssetFingerprint = refreshed.suggestionFingerprint
            suggestionRevision &+= 1
        }
        if albums != refreshed.albums { albums = refreshed.albums }
        snapshot = refreshed
        if !hasLoaded {
            await prepareInitialCovers(refreshed.albums)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
        }
        hasLoaded = true
        revision &+= 1
    }

    private func prepareInitialCovers(_ albums: [LibraryAlbum]) async {
        let identifiers = Array(Set(albums.filter { $0.smartSubtypeRawValue == nil }
            .prefix(8).compactMap(\.coverAssetIdentifier)))
        await withTaskGroup(of: Void.self) { group in
            for identifier in identifiers {
                group.addTask { [weak self] in
                    let image = await PhotoImageLoader.load(identifier: identifier,
                        targetSize: CGSize(width: 640, height: 640), allowNetwork: false,
                        contentMode: .aspectFit, deliveryMode: .fastFormat, timeout: .seconds(3))
                    guard !Task.isCancelled, let image else { return }
                    await self?.cacheInitialCover(image, identifier: identifier)
                }
            }
        }
    }

    private func cacheInitialCover(_ image: UIImage, identifier: String) {
        guard let asset = assetsByIdentifier[identifier] else { return }
        cacheQuickPreview(image, for: asset)
    }

    private func invalidatePreview(identifier: String) {
        quickPreviewCache.removeObject(forKey: identifier as NSString)
        reviewPreviewCache.removeObject(forKey: identifier as NSString)
        quickPreviewTasks.removeValue(forKey: identifier)?.cancel()
        reviewPreviewTasks.removeValue(forKey: identifier)?.cancel()
        networkPreviewTasks.removeValue(forKey: identifier)?.cancel()
        localVideoItemTasks.removeValue(forKey: identifier)?.cancel()
        quickPreviewTokens.removeValue(forKey: identifier)
        reviewPreviewTokens.removeValue(forKey: identifier)
        networkPreviewTokens.removeValue(forKey: identifier)
        unavailableLocalReviewIDs.remove(identifier)
        cloudAssetIdentifiers.remove(identifier)
    }

    /// Returns assets matching a library scope. `.later` is intentionally left
    /// to the UI, which has access to ReviewStore's persisted decisions.
    func assets(in scope: LibraryScope) -> [PHAsset] {
        switch scope {
        case .all, .random: return assets
        case .month(let date):
            guard let start = Calendar.autoupdatingCurrent.dateInterval(of: .month, for: date)?.start else { return [] }
            return scopedAssets[.month(start)] ?? []
        case .year(let date):
            guard let start = Calendar.autoupdatingCurrent.dateInterval(of: .year, for: date)?.start else { return [] }
            return scopedAssets[.year(start)] ?? []
        case .later: return []
        default: return scopedAssets[scope] ?? []
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

    /// Prepares the selected photo or video for the native share sheet. This
    /// runs only after the user taps Share; iCloud data may be downloaded as
    /// part of that explicit action. A Live Photo is kept as one
    /// `PHLivePhoto` item built from its matching still and paired-video
    /// resources, rather than being presented as two unrelated attachments.
    func exportForSharing(_ asset: PHAsset) async throws -> PhotoSharePayload {
        let resources = PHAssetResource.assetResources(for: asset)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeyingShare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var temporaryURLs: [URL] = []
        do {
            if asset.mediaSubtypes.contains(.photoLive) {
                guard let pair = PhotoShareResourceSelection.livePhotoPair(in: resources) else {
                    throw PhotoLibraryServiceError.shareFailed(
                        String(localized: "无法找到与这张实况照片匹配的原始资源。")
                    )
                }
                let stillURL = folder.appendingPathComponent(
                    PhotoShareResourceSelection.safeFilename(
                        for: pair.photo, fallbackExtension: "jpg"
                    )
                )
                let pairedVideoURL = folder.appendingPathComponent(
                    PhotoShareResourceSelection.safeFilename(
                        for: pair.pairedVideo, fallbackExtension: "mov"
                    )
                )
                temporaryURLs = [stillURL, pairedVideoURL]

                try await streamShareResource(pair.photo, to: stillURL)
                try await streamShareResource(pair.pairedVideo, to: pairedVideoURL)
                let livePhoto = try await makeShareLivePhoto(
                    stillURL: stillURL, pairedVideoURL: pairedVideoURL
                )
                return PhotoSharePayload(
                    items: [.livePhoto(livePhoto)],
                    temporaryURLs: temporaryURLs + [folder]
                )
            }

            guard let resource = PhotoShareResourceSelection.preferredResource(
                for: asset, in: resources
            ) else {
                throw PhotoLibraryServiceError.shareFailed(
                    String(localized: "无法找到这张照片或视频的可分享文件。")
                )
            }

            let fileURL = folder.appendingPathComponent(
                PhotoShareResourceSelection.safeFilename(
                    for: resource,
                    fallbackExtension: asset.mediaType == .video ? "mov" : "jpg"
                )
            )
            temporaryURLs = [fileURL]
            try await streamShareResource(resource, to: fileURL)
            return PhotoSharePayload(items: [.file(fileURL)], temporaryURLs: temporaryURLs + [folder])
        } catch is CancellationError {
            cleanupShareFiles(temporaryURLs + [folder])
            throw CancellationError()
        } catch let error as PhotoLibraryServiceError {
            cleanupShareFiles(temporaryURLs + [folder])
            throw error
        } catch {
            cleanupShareFiles(temporaryURLs + [folder])
            throw PhotoLibraryServiceError.shareFailed(PhotosFailureMessage.message(for: error))
        }
    }

    private func streamShareResource(_ resource: PHAssetResource, to fileURL: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let request = try ShareResourceDataRequest(fileURL: fileURL)
        let manager = PHAssetResourceManager.default()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard request.install(continuation) else { return }
                let requestID = manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in request.receive(data) },
                    completionHandler: { error in request.finish(error: error) }
                )
                request.install(requestID: requestID, manager: manager)
            }
        } onCancel: {
            request.cancel(using: manager)
        }
    }

    private func makeShareLivePhoto(stillURL: URL, pairedVideoURL: URL) async throws -> PHLivePhoto {
        let request = ShareLivePhotoRequest()
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHLivePhoto, Error>) in
                guard request.install(continuation) else { return }
                let requestID = PHLivePhoto.request(
                    withResourceFileURLs: [stillURL, pairedVideoURL],
                    placeholderImage: nil,
                    targetSize: .zero,
                    contentMode: .aspectFit
                ) { livePhoto, info in
                    let cancelled = (info[PHLivePhotoInfoCancelledKey] as? Bool) == true
                    if cancelled {
                        request.finish(error: CancellationError())
                    } else if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                        request.finish(error: error)
                    } else if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) != true {
                        if let livePhoto {
                            request.finish(livePhoto: livePhoto)
                        } else {
                            request.finish(error: PhotoLibraryServiceError.shareFailed(
                                String(localized: "无法读取这张实况照片的原始资源。")
                            ))
                        }
                    }
                }
                request.install(requestID: requestID)
            }
        } onCancel: {
            request.cancel()
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
        await PhotoImageLoader.load(identifier: asset.localIdentifier, targetSize: targetSize,
            allowNetwork: allowNetwork, contentMode: contentMode,
            deliveryMode: deliveryMode ?? (allowNetwork ? .highQualityFormat : .opportunistic),
            timeout: allowNetwork ? nil : .seconds(5), onDegraded: onDegraded,
            onCloud: { [weak self] in self?.cloudAssetIdentifiers.insert(asset.localIdentifier) })
    }

    func isKnownCloudAsset(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image && cloudAssetIdentifiers.contains(asset.localIdentifier)
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
    var reviewPrefetchBudget: ReviewPrefetchBudget {
        ReviewPrefetchBudget.current(thermalState: ProcessInfo.processInfo.thermalState,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryPressure: Date.now < memoryPressureUntil)
    }

    func updatePerformanceBudget(memoryWarning: Bool = false) {
        if memoryWarning {
            memoryPressureUntil = .now.addingTimeInterval(30)
            let current = lastPrefetchCurrentIdentifier.flatMap { assetsByIdentifier[$0] }
            let currentImage = current.flatMap { cachedReviewPreview(for: $0) ?? cachedQuickPreview(for: $0) }
            let next = lastPrefetchCandidates.first
            let nextImage = next.flatMap { cachedQuickPreview(for: $0) ?? cachedReviewPreview(for: $0) }
            quickPreviewCache.removeAllObjects()
            reviewPreviewCache.removeAllObjects()
            if let current, let currentImage { cacheReviewPreview(currentImage, for: current) }
            if let next, let nextImage { cacheQuickPreview(nextImage, for: next) }
            memoryRecoveryTask?.cancel()
            memoryRecoveryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.updatePerformanceBudget()
            }
        }
        if let current = lastPrefetchCurrentIdentifier {
            prefetchReviewPreviews(lastPrefetchCandidates, keeping: current)
        }
        prefetchRevision &+= 1
    }

    func prefetchReviewPreviews(_ upcoming: [PHAsset], keeping currentIdentifier: String) {
        lastPrefetchCandidates = Array(upcoming.prefix(5))
        lastPrefetchCurrentIdentifier = currentIdentifier
        let budget = reviewPrefetchBudget
        let candidates = lastPrefetchCandidates
        let nextVideo = budget.videoCount > 0 ? candidates.prefix(2).first { $0.mediaType == .video } : nil
        let neededReview = Set([currentIdentifier] + candidates.prefix(budget.highQualityCount).map(\.localIdentifier) +
                               (budget.highQualityCount > 0 ? [nextVideo?.localIdentifier].compactMap { $0 } : []))
        let neededQuick = Set([currentIdentifier] + candidates.prefix(budget.quickCount).map(\.localIdentifier))
        let neededVideo = Set([currentIdentifier] + [nextVideo?.localIdentifier].compactMap { $0 })
        for id in reviewPreviewTasks.keys.filter({ !neededReview.contains($0) }) {
            reviewPreviewTasks.removeValue(forKey: id)?.cancel()
            reviewPreviewTokens.removeValue(forKey: id)
        }
        for id in quickPreviewTasks.keys.filter({ !neededQuick.contains($0) }) {
            quickPreviewTasks.removeValue(forKey: id)?.cancel()
            quickPreviewTokens.removeValue(forKey: id)
        }
        for id in localVideoItemTasks.keys.filter({ !neededVideo.contains($0) }) {
            localVideoItemTasks.removeValue(forKey: id)?.cancel()
        }
        for id in networkPreviewTasks.keys.filter({ $0 != currentIdentifier }) {
            networkPreviewTasks.removeValue(forKey: id)?.cancel()
            networkPreviewTokens.removeValue(forKey: id)
        }
        for asset in candidates.prefix(budget.quickCount)
        where asset.mediaType != .video &&
            cachedQuickPreview(for: asset) == nil && cachedReviewPreview(for: asset) == nil {
            _ = quickPreviewTask(for: asset)
        }
        for asset in candidates.prefix(budget.highQualityCount) where asset.mediaType != .video {
            if cachedReviewPreview(for: asset) == nil, !unavailableLocalReviewIDs.contains(asset.localIdentifier) {
                _ = reviewPreviewTask(for: asset)
            }
        }
        if budget.highQualityCount > 0, let nextVideo,
           cachedReviewPreview(for: nextVideo) == nil,
           !unavailableLocalReviewIDs.contains(nextVideo.localIdentifier) {
            _ = reviewPreviewTask(for: nextVideo)
        }
        if let nextVideo, localVideoItemTasks[nextVideo.localIdentifier] == nil {
            localVideoItemTasks[nextVideo.localIdentifier] = Task(priority: .utility) { [weak self] in
                await self?.requestPlayerItemDirect(for: nextVideo, allowNetwork: false)
            }
        }
    }

    func prepareUpcomingPreview(for asset: PHAsset) async -> UIImage? {
        if asset.mediaType == .video {
            return await prepareVideoPoster(for: asset)
        }
        let quick = await quickPreview(for: asset)
        guard !Task.isCancelled else { return nil }
        if reviewPrefetchBudget.highQualityCount > 0 {
            return await prepareReviewPreview(for: asset) ?? quick
        }
        return quick
    }

    func prepareReviewPreview(for asset: PHAsset, allowNetwork: Bool = false) async -> UIImage? {
        // Video playback and the clear poster prepare independently. Do not
        // make opening the review queue wait for a video still request.
        if asset.mediaType == .video { return cachedReviewPreview(for: asset) }
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

    /// A video poster is displayed only after PhotoKit has delivered its
    /// full-quality local rendition. The player can start in parallel.
    func prepareVideoPoster(for asset: PHAsset) async -> UIImage? {
        guard asset.mediaType == .video else { return nil }
        if let cached = cachedReviewPreview(for: asset) { return cached }
        guard !unavailableLocalReviewIDs.contains(asset.localIdentifier) else { return nil }
        return await reviewPreviewTask(for: asset).value
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
        lastPrefetchCandidates = []
        lastPrefetchCurrentIdentifier = nil
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
                targetSize: CGSize(width: 640, height: 640),
                allowNetwork: false,
                contentMode: .aspectFit,
                deliveryMode: .fastFormat
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

    func requestVideoPreview(for asset: PHAsset, allowNetwork: Bool = false) async -> VideoPreviewResult {
        guard !Task.isCancelled else { return VideoPreviewResult(item: nil, needsDownload: false) }
        if !allowNetwork, let prefetched = localVideoItemTasks.removeValue(forKey: asset.localIdentifier) {
            let item = await withTaskCancellationHandler { await prefetched.value } onCancel: { prefetched.cancel() }
            if let item { return VideoPreviewResult(item: item, needsDownload: false) }
        }
        return await VideoPreviewLoader.loadResult(identifier: asset.localIdentifier, allowNetwork: allowNetwork)
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
            if !identifiers.isEmpty { scheduleRefresh() }
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

        // The registered PhotoKit change observer refreshes the snapshot.
        // A synchronous full refresh here would scan the library a second
        // time before List can finish its local deletion records.
        return deletedIdentifiers
    }

    // MARK: - PHPhotoLibraryChangeObserver

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            pendingChanges.append(changeInstance)
            guard changeRefreshTask == nil else { return }
            changeRefreshTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { changeRefreshTask = nil }
                try? await Task.sleep(for: .milliseconds(300))
                while !Task.isCancelled, !pendingChanges.isEmpty {
                    // Let an active refresh commit before applying the next
                    // change, so a cancelled intermediate change is not lost.
                    if let refreshTask { await refreshTask.value }
                    guard !Task.isCancelled else { return }
                    let changes = pendingChanges
                    pendingChanges.removeAll()
                    await startRefresh(changes: changes).value
                }
            }
        }
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
        snapshot = nil
        scopedAssets = [:]
        monthBuckets = []
        yearBuckets = []
        suggestionAssets = []
        assetSnapshotFingerprint = nil
        suggestionAssetFingerprint = nil
        assetRevision &+= 1
        albumMembershipRevision &+= 1
        stopReviewPrefetching()
        quickPreviewCache.removeAllObjects()
        reviewPreviewCache.removeAllObjects()
        unavailableLocalReviewIDs.removeAll()
        cloudAssetIdentifiers.removeAll()
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

struct PhotoSharePayload: Identifiable {
    let id = UUID()
    let items: [PhotoShareItem]
    let temporaryURLs: [URL]

    func cleanup() {
        cleanupShareFiles(temporaryURLs)
    }
}

enum PhotoShareItem {
    case file(URL)
    case livePhoto(PHLivePhoto)
}

enum PhotoShareResourceSelection {
    private static let livePhotoPairs: [(PHAssetResourceType, PHAssetResourceType)] = [
        (.photo, .pairedVideo),
        (.fullSizePhoto, .fullSizePairedVideo),
        (.adjustmentBasePhoto, .adjustmentBasePairedVideo),
    ]

    static func livePhotoPair(
        in resources: [PHAssetResource]
    ) -> (photo: PHAssetResource, pairedVideo: PHAssetResource)? {
        let availableTypes = Set(resources.map(\.type))
        guard let pair = livePhotoPairTypes(availableTypes: availableTypes) else {
            return nil
        }
        return matchingResources(resources, photoType: pair.photo, videoType: pair.pairedVideo)
    }

    static func livePhotoPairTypes(
        availableTypes: Set<PHAssetResourceType>
    ) -> (photo: PHAssetResourceType, pairedVideo: PHAssetResourceType)? {
        for (photoType, videoType) in livePhotoPairs {
            guard availableTypes.contains(photoType), availableTypes.contains(videoType) else {
                continue
            }
            return (photoType, videoType)
        }
        return nil
    }

    private static func matchingResources(
        _ resources: [PHAssetResource],
        photoType: PHAssetResourceType,
        videoType: PHAssetResourceType
    ) -> (photo: PHAssetResource, pairedVideo: PHAssetResource)? {
        guard let photo = resources.first(where: { $0.type == photoType }),
              let pairedVideo = resources.first(where: { $0.type == videoType }) else {
            return nil
        }
        return (photo, pairedVideo)
    }

    static func preferredResource(
        for asset: PHAsset,
        in resources: [PHAssetResource]
    ) -> PHAssetResource? {
        let preferredTypes: [PHAssetResourceType] = asset.mediaType == .video
            ? [.video, .fullSizeVideo]
            : [.photo, .fullSizePhoto]
        return preferredTypes.compactMap { preferred in
            resources.first(where: { $0.type == preferred })
        }.first
    }

    static func safeFilename(for resource: PHAssetResource, fallbackExtension: String) -> String {
        let resourceFilename: String
        if #available(iOS 27.0, *) {
            resourceFilename = resource.filename ?? resource.originalFilename
        } else {
            resourceFilename = resource.originalFilename
        }
        let original = URL(fileURLWithPath: resourceFilename).lastPathComponent
        guard !original.isEmpty, original != "." else {
            let extensionName = resource.contentType.preferredFilenameExtension ?? fallbackExtension
            return "\(UUID().uuidString).\(extensionName)"
        }
        return original
    }
}

private func cleanupShareFiles(_ urls: [URL]) {
    // Export callers append the containing folder after its files. Remove
    // files first so the folder can be removed as well.
    for url in urls {
        try? FileManager.default.removeItem(at: url)
    }
}

final class ShareResourceDataRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let fileHandle: FileHandle
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var manager: PHAssetResourceManager?
    private var isFinished = false

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            fileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(requestID: PHAssetResourceDataRequestID, manager: PHAssetResourceManager) {
        lock.lock()
        self.requestID = requestID
        self.manager = manager
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel {
            manager.cancelDataRequest(requestID)
        }
    }

    func receive(_ data: Data) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(error: error)
        }
    }

    func finish(error: Error?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let requestID = self.requestID
        let manager = self.manager
        lock.unlock()

        try? fileHandle.close()
        if let error {
            if let requestID {
                manager?.cancelDataRequest(requestID)
            }
            try? FileManager.default.removeItem(at: fileURL)
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    func cancel(using manager: PHAssetResourceManager) {
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
            manager.cancelDataRequest(requestID)
        }
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: fileURL)
        continuation?.resume(throwing: CancellationError())
    }
}

private final class ShareLivePhotoRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PHLivePhoto, Error>?
    private var requestID: PHLivePhotoRequestID?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<PHLivePhoto, Error>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(requestID: PHLivePhotoRequestID) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()
        if shouldCancel {
            PHLivePhoto.cancelRequest(withRequestID: requestID)
        }
    }

    func finish(livePhoto: PHLivePhoto) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: livePhoto)
    }

    func finish(error: Error) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func cancel() {
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
            PHLivePhoto.cancelRequest(withRequestID: requestID)
        }
        continuation?.resume(throwing: CancellationError())
    }
}

struct VideoPreviewResult {
    let item: AVPlayerItem?
    let needsDownload: Bool
}

private enum VideoPreviewLoader {
    @concurrent
    static func load(identifier: String, allowNetwork: Bool) async -> AVPlayerItem? {
        await loadResult(identifier: identifier, allowNetwork: allowNetwork).item
    }

    @concurrent
    static func loadResult(identifier: String, allowNetwork: Bool) async -> VideoPreviewResult {
        let unavailable = VideoPreviewResult(item: nil, needsDownload: false)
        guard !Task.isCancelled,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              !Task.isCancelled else { return unavailable }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.version = .current
        options.isNetworkAccessAllowed = allowNetwork
        let manager = PHImageManager.default()
        let request = OneShotContinuation<VideoPreviewResult>(cancellationValue: unavailable)
        // Local autoplay is opportunistic. A slow original should leave a
        // poster and a manual play button instead of an indefinite spinner.
        let timeout: Task<Void, Never>? = allowNetwork ? nil : Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            request.finishEarly(returning: unavailable, using: manager)
        }
        defer { timeout?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    request.resume(returning: VideoPreviewResult(
                        item: cancelled || info?[PHImageErrorKey] != nil ? nil : item,
                        needsDownload: !cancelled && !allowNetwork && item == nil &&
                            (info?[PHImageResultIsInCloudKey] as? Bool) == true
                    ))
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
