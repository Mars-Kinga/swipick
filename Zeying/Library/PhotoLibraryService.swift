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
    @ObservationIgnored private var assetsByIdentifier: [String: PHAsset] = [:]
    @ObservationIgnored private let quickPreviewCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private let reviewPreviewCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var quickPreviewTasks: [String: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var quickPreviewTokens: [String: UUID] = [:]
    @ObservationIgnored private var reviewPrefetchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reviewPrefetchTokens: [String: UUID] = [:]

    private(set) var authorizationStatus: PHAuthorizationStatus
    private(set) var assets: [PHAsset] = []
    private(set) var albums: [LibraryAlbum] = []
    private(set) var revision = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        // NSCache may evict earlier under memory pressure. These limits keep
        // several upcoming Live Photo still frames ready without retaining motion.
        quickPreviewCache.countLimit = 12
        quickPreviewCache.totalCostLimit = 64 * 1_024 * 1_024
        reviewPreviewCache.countLimit = 4
        reviewPreviewCache.totalCostLimit = 48 * 1_024 * 1_024
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

        let refreshedAssets = await fetchAllAssets()
        guard !Task.isCancelled, generation == refreshGeneration else { return }

        let refreshedAlbums = await fetchAlbums(authorizedAssets: refreshedAssets)
        let finalStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = finalStatus
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        guard Self.canRead(finalStatus) else {
            clearSnapshot()
            return
        }
        // An external edit can keep the same local identifier while changing
        // its pixels. Never show an older cached card after a library refresh.
        stopReviewPrefetching()
        quickPreviewCache.removeAllObjects()
        reviewPreviewCache.removeAllObjects()
        assets = refreshedAssets
        assetsByIdentifier = Dictionary(
            uniqueKeysWithValues: refreshedAssets.map { ($0.localIdentifier, $0) }
        )
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
            throw PhotoLibraryServiceError.shareFailed(error.localizedDescription)
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
        // The review card can show PhotoKit's locally available preview while
        // the final image is prepared, including for an iCloud-backed asset.
        options.deliveryMode = deliveryMode ?? (onDegraded == nil && allowNetwork ? .highQualityFormat : .opportunistic)
        options.resizeMode = .fast
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
                    } else if isDegraded, let image {
                        if let onDegraded {
                            Task { @MainActor in onDegraded(image) }
                        }
                        if !allowNetwork, onDegraded == nil, deliveryMode != .highQualityFormat {
                            request.finishEarly(returning: image, using: manager)
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

    /// Prepare five nearby still frames or video posters and two full review
    /// images. Live Photo motion is loaded only on hold.
    /// Prefetch never downloads an iCloud original.
    func prefetchReviewPreviews(_ upcoming: [PHAsset], keeping currentIdentifier: String) {
        let candidates = Array(upcoming.prefix(5))
        let quickNeeded = Set([currentIdentifier] + candidates.map(\.localIdentifier))
        for identifier in quickPreviewTasks.keys.filter({ !quickNeeded.contains($0) }) {
            quickPreviewTasks[identifier]?.cancel()
            quickPreviewTasks.removeValue(forKey: identifier)
            quickPreviewTokens.removeValue(forKey: identifier)
        }

        let fullCandidates = Array(candidates.filter { $0.mediaType == .image }.prefix(2))
        let fullCandidateIDs = Set(fullCandidates.map(\.localIdentifier))
        let fullNeeded = Set([currentIdentifier] + fullCandidates.map(\.localIdentifier))
        for identifier in reviewPrefetchTasks.keys.filter({ !fullNeeded.contains($0) }) {
            reviewPrefetchTasks[identifier]?.cancel()
            reviewPrefetchTasks.removeValue(forKey: identifier)
            reviewPrefetchTokens.removeValue(forKey: identifier)
        }

        for asset in candidates {
            let identifier = asset.localIdentifier
            let quickTask: Task<UIImage?, Never>?
            if cachedQuickPreview(for: asset) != nil || cachedReviewPreview(for: asset) != nil {
                quickTask = nil
            } else {
                quickTask = quickPreviewTask(for: asset)
            }

            guard fullCandidateIDs.contains(identifier), cachedReviewPreview(for: asset) == nil,
                  reviewPrefetchTasks[identifier] == nil else { continue }
            let token = UUID()
            reviewPrefetchTokens[identifier] = token
            reviewPrefetchTasks[identifier] = Task(priority: .utility) { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.reviewPrefetchTokens[identifier] == token {
                        self.reviewPrefetchTasks.removeValue(forKey: identifier)
                        self.reviewPrefetchTokens.removeValue(forKey: identifier)
                    }
                }
                if let quickTask { _ = await quickTask.value }
                guard !Task.isCancelled else { return }
                let image = await self.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 1_500, height: 1_500),
                    allowNetwork: false,
                    contentMode: .aspectFit,
                    deliveryMode: .highQualityFormat
                )
                if !Task.isCancelled, let image {
                    self.cacheReviewPreview(image, for: asset)
                }
            }
        }
    }

    func stopReviewPrefetching() {
        for task in quickPreviewTasks.values { task.cancel() }
        quickPreviewTasks.removeAll()
        quickPreviewTokens.removeAll()
        for task in reviewPrefetchTasks.values { task.cancel() }
        reviewPrefetchTasks.removeAll()
        reviewPrefetchTokens.removeAll()
    }

    func quickPreview(for asset: PHAsset) async -> UIImage? {
        if let cached = cachedQuickPreview(for: asset) { return cached }
        if let cached = cachedReviewPreview(for: asset) { return cached }
        return await quickPreviewTask(for: asset).value
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
                targetSize: CGSize(width: 1_000, height: 1_000),
                allowNetwork: false,
                contentMode: .aspectFit
            )
            guard !Task.isCancelled, let image else { return nil }
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            self.quickPreviewCache.setObject(image, forKey: identifier as NSString, cost: cost)
            return image
        }
        quickPreviewTasks[identifier] = task
        return task
    }

    /// Loads the motion component only after the user long-presses a Live Photo.
    func requestLivePhoto(for asset: PHAsset) async -> PHLivePhoto? {
        guard !Task.isCancelled, asset.mediaSubtypes.contains(.photoLive) else { return nil }

        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

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

    /// Requests an AVPlayerItem for a video asset.
    func requestPlayerItem(for asset: PHAsset) async -> AVPlayerItem? {
        guard !Task.isCancelled else { return nil }

        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.version = .current
        options.isNetworkAccessAllowed = true

        let manager = PHImageManager.default()
        let request = OneShotContinuation<AVPlayerItem?>(cancellationValue: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    let hasError = info?[PHImageErrorKey] != nil
                    guard !isCancelled, !hasError, let avAsset else {
                        request.resume(returning: nil)
                        return
                    }
                    request.resume(returning: AVPlayerItem(asset: avAsset))
                }
                request.install(requestID: requestID, manager: manager)
            }
        } onCancel: {
            request.cancel(using: manager)
        }
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
            throw PhotoLibraryServiceError.changeFailed(error.localizedDescription)
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
                throw PhotoLibraryServiceError.changeFailed(error.localizedDescription)
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
            throw PhotoLibraryServiceError.changeFailed(error.localizedDescription)
        }

        await refresh()
        return deletedIdentifiers
    }

    // MARK: - PHPhotoLibraryChangeObserver

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - Fetching

    private func fetchAllAssets() async -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)

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

    private func fetchAlbums(authorizedAssets: [PHAsset]) async -> [LibraryAlbum] {
        let authorizedIdentifiers = Set(authorizedAssets.map(\.localIdentifier))
        var collections: [PHAssetCollection] = []

        for (type, subtype) in [
            (PHAssetCollectionType.album, PHAssetCollectionSubtype.any),
            (PHAssetCollectionType.smartAlbum, PHAssetCollectionSubtype.any)
        ] {
            let result = PHAssetCollection.fetchAssetCollections(with: type, subtype: subtype, options: nil)
            for index in 0..<result.count {
                guard !Task.isCancelled else { return [] }
                collections.append(result.object(at: index))
                if index.isMultiple(of: 32) {
                    await Task.yield()
                    guard !Task.isCancelled else { return [] }
                }
            }
        }

        var result: [LibraryAlbum] = []
        result.reserveCapacity(collections.count)

        for (collectionIndex, collection) in collections.enumerated() where shouldInclude(collection) {
            guard !Task.isCancelled else { return [] }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let collectionAssets = PHAsset.fetchAssets(in: collection, options: options)

            var count = 0
            var coverIdentifier: String?
            for assetIndex in 0..<collectionAssets.count {
                guard !Task.isCancelled else { return [] }
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
                if assetIndex.isMultiple(of: 256), Task.isCancelled { return [] }
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
                guard !Task.isCancelled else { return [] }
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
        stopReviewPrefetching()
        quickPreviewCache.removeAllObjects()
        reviewPreviewCache.removeAllObjects()
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

private final class OneShotContinuation<Value>: @unchecked Sendable {
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
