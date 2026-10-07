@preconcurrency import Photos
import Foundation
import Observation

struct PhotoAlbumOption: Identifiable, Hashable {
    let id: String
    let title: String
    /// PhotoKit's estimate can be unavailable for an album.  Keep it
    /// optional so refreshing the picker never has to scan every album.
    let count: Int?
}

struct PhotoAlbumMembership: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let canRemove: Bool
}

struct PhotoAlbumSelection: Hashable {
    let identifier: String?
    let title: String

    var isNewAlbum: Bool { identifier == nil }
}

struct PhotoAlbumApplyResult {
    let appliedIdentifiers: [String]
    let failedIdentifiers: [String]
    let errorMessage: String?

    var didApplyAny: Bool { !appliedIdentifiers.isEmpty }
}

enum PhotoAlbumServiceError: LocalizedError {
    case authorizationRequired(PHAuthorizationStatus)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired(let status):
            switch status {
            case .notDetermined:
                String(localized: "需要先获得照片图库权限。")
            case .restricted:
                String(localized: "系统限制了照片图库访问。")
            case .denied:
                String(localized: "没有照片图库写入权限。")
            case .limited:
                String(localized: "当前只能整理已获准访问的照片。")
            case .authorized:
                String(localized: "照片图库权限有效。")
            @unknown default:
                String(localized: "照片图库权限不可用。")
            }
        }
    }
}

/// PhotoKit operations for user-created albums. This is intentionally kept
/// separate from PhotoLibraryService so album mutations cannot interfere with
/// the library snapshot or the Live Photo conversion flow.
@MainActor
@Observable
final class PhotoAlbumService {
    private static let albumUseKey = "com.mars.zeying.albumSelectionCounts.v1"
    private static let newlyCreatedAlbumKey = "com.mars.zeying.newlyCreatedAlbum.v1"
    private let photoLibrary = PHPhotoLibrary.shared()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var selectionCounts: [String: Int] =
        UserDefaults.standard.dictionary(forKey: PhotoAlbumService.albumUseKey) as? [String: Int] ?? [:]
    @ObservationIgnored private var membershipsByAsset: [String: [PhotoAlbumMembership]] = [:]
    @ObservationIgnored private var membershipGeneration = 0
    @ObservationIgnored private var membershipLibraryRevision: Int?
    @ObservationIgnored private var newlyCreatedAlbumIdentifier: String? =
        UserDefaults.standard.string(forKey: PhotoAlbumService.newlyCreatedAlbumKey)

    private(set) var albums: [PhotoAlbumOption] = []
    private(set) var frequentlyUsedFirst: [PhotoAlbumOption] = []
    private(set) var revision = 0
    private(set) var membershipRevision = 0

    func memberships(for assetIdentifier: String) -> [PhotoAlbumMembership]? {
        _ = membershipRevision
        return membershipsByAsset[assetIdentifier]
    }

    /// PhotoKit's membership query is synchronous. Run it away from the card's
    /// animation and cache the result until the library snapshot changes.
    func loadMemberships(
        for assetIdentifier: String,
        libraryRevision: Int,
        publishChange: Bool = true
    ) async {
        if membershipLibraryRevision != libraryRevision {
            invalidateMemberships()
            membershipLibraryRevision = libraryRevision
        }
        guard membershipsByAsset[assetIdentifier] == nil else { return }
        let generation = membershipGeneration
        let memberships = await Task.detached(priority: .userInitiated) {
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [assetIdentifier], options: nil
            ).firstObject else { return [PhotoAlbumMembership]() }
            let result = PHAssetCollection.fetchAssetCollectionsContaining(
                asset, with: .album, options: nil
            )
            var found: [PhotoAlbumMembership] = []
            for index in 0..<result.count {
                let collection = result.object(at: index)
                guard collection.assetCollectionSubtype == .albumRegular,
                      let title = collection.localizedTitle, !title.isEmpty else { continue }
                found.append(PhotoAlbumMembership(
                    id: collection.localIdentifier,
                    title: title,
                    canRemove: collection.canPerform(.removeContent)
                ))
            }
            return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
        guard generation == membershipGeneration, !Task.isCancelled else { return }
        membershipsByAsset[assetIdentifier] = memberships
        // The next card is prefetched in the background. Publishing that
        // result while the current card is moving invalidates its whole view.
        if publishChange { membershipRevision += 1 }
    }

    private func invalidateMemberships() {
        membershipsByAsset.removeAll()
        membershipGeneration += 1
        membershipRevision += 1
    }

    private func orderByRecentUse() -> [PhotoAlbumOption] {
        albums.sorted { left, right in
            if left.id == newlyCreatedAlbumIdentifier { return true }
            if right.id == newlyCreatedAlbumIdentifier { return false }
            let leftCount = selectionCounts[left.id, default: 0]
            let rightCount = selectionCounts[right.id, default: 0]
            if leftCount != rightCount { return leftCount > rightCount }
            let ordering = left.title.localizedStandardCompare(right.title)
            return ordering == .orderedSame ? left.id < right.id : ordering == .orderedAscending
        }
    }

    func recordSelection(of albumIdentifier: String) {
        selectionCounts[albumIdentifier, default: 0] += 1
        if newlyCreatedAlbumIdentifier != albumIdentifier {
            newlyCreatedAlbumIdentifier = nil
            defaults.removeObject(forKey: Self.newlyCreatedAlbumKey)
        }
        defaults.set(selectionCounts, forKey: Self.albumUseKey)
        frequentlyUsedFirst = orderByRecentUse()
        revision += 1
    }

    func refresh() {
        invalidateMemberships()
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.canRead(status) else {
            albums = []
            frequentlyUsedFirst = []
            revision += 1
            return
        }

        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )

        var options: [PhotoAlbumOption] = []
        options.reserveCapacity(result.count)
        for index in 0..<result.count {
            let collection = result.object(at: index)
            let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { continue }
            guard collection.canPerform(.addContent) else { continue }
            let estimatedCount = collection.estimatedAssetCount
            options.append(
                PhotoAlbumOption(
                    id: collection.localIdentifier,
                    title: title,
                    count: estimatedCount == NSNotFound ? nil : Int(estimatedCount)
                )
            )
        }

        albums = options.sorted {
            let ordering = $0.title.localizedStandardCompare($1.title)
            if ordering == .orderedSame { return $0.id < $1.id }
            return ordering == .orderedAscending
        }
        frequentlyUsedFirst = orderByRecentUse()
        revision += 1
    }

    /// Create a real Photos album before asking whether to add the current asset.
    func createAlbumImmediately(title: String) async throws -> PhotoAlbumOption {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.canRead(status) else {
            throw PhotoAlbumServiceError.authorizationRequired(status)
        }
        let identifier = try await createAlbum(title: title)
        newlyCreatedAlbumIdentifier = identifier
        defaults.set(identifier, forKey: Self.newlyCreatedAlbumKey)
        refresh()
        if !albums.contains(where: { $0.id == identifier }) {
            // PhotoKit can publish the collection a moment after the change
            // callback. Retry once before reporting it unavailable.
            try await Task.sleep(for: .milliseconds(150))
            refresh()
        }
        guard let option = albums.first(where: { $0.id == identifier }) else {
            throw AlbumOperationError.collectionUnavailable(title)
        }
        return option
    }

    /// Add one asset now, after the user confirms the new album destination.
    func add(assetIdentifier: String, to albumIdentifier: String) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.canRead(status) else {
            throw PhotoAlbumServiceError.authorizationRequired(status)
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier], options: nil
        ).firstObject else {
            throw AlbumOperationError.assetUnavailable
        }
        guard let collection = fetchCollection(with: albumIdentifier),
              collection.assetCollectionType == .album,
              collection.assetCollectionSubtype == .albumRegular,
              collection.canPerform(.addContent) else {
            throw AlbumOperationError.albumUnavailable
        }
        if Self.contains(asset, in: collection) { return }
        try await add([asset], to: collection)
        guard confirmedMembership(of: [asset], in: collection).contains(assetIdentifier) else {
            throw AlbumOperationError.additionUnconfirmed
        }
        invalidateMemberships()
        recordSelection(of: albumIdentifier)
    }

    /// Removes only this album membership. The asset remains in the library
    /// and in every other album.
    func remove(assetIdentifier: String, from albumIdentifier: String) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.canRead(status) else {
            throw PhotoAlbumServiceError.authorizationRequired(status)
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier], options: nil
        ).firstObject else {
            throw AlbumOperationError.assetUnavailable
        }
        guard let collection = fetchCollection(with: albumIdentifier),
              collection.assetCollectionType == .album,
              collection.assetCollectionSubtype == .albumRegular else {
            throw AlbumOperationError.albumUnavailable
        }
        guard Self.contains(asset, in: collection) else {
            invalidateMemberships()
            return
        }
        guard collection.canPerform(.removeContent) else {
            throw AlbumOperationError.removalNotAllowed
        }

        let albumAssets = PHAsset.fetchAssets(in: collection, options: nil)
        try await performChanges {
            PHAssetCollectionChangeRequest(for: collection, assets: albumAssets)?
                .removeAssets([asset] as NSArray)
        }
        guard !Self.contains(asset, in: collection) else {
            throw AlbumOperationError.removalUnconfirmed
        }
        invalidateMemberships()
    }

    private static func contains(_ asset: PHAsset, in collection: PHAssetCollection) -> Bool {
        let result = PHAssetCollection.fetchAssetCollectionsContaining(
            asset, with: .album, options: nil
        )
        for index in 0..<result.count where result.object(at: index).localIdentifier == collection.localIdentifier {
            return true
        }
        return false
    }

    /// Adds each pending assignment to its existing album or creates the
    /// requested new album first. Successful assets are returned individually
    /// so a partial PhotoKit failure never clears unrelated local work.
    func apply(
        _ assignments: [PendingAlbumAssignment],
        onAlbumCreationIntent: (String, [String], [String]) -> Bool,
        onCreatedAlbum: (String, String, [String]) -> Bool
    ) async throws -> PhotoAlbumApplyResult {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.canRead(status) else {
            throw PhotoAlbumServiceError.authorizationRequired(status)
        }

        let usable = assignments.filter { !$0.assetIdentifier.isEmpty }
        guard !usable.isEmpty else {
            return PhotoAlbumApplyResult(appliedIdentifiers: [], failedIdentifiers: [], errorMessage: nil)
        }

        // A single review can only have one target album. Grouping keeps a
        // final confirmation to one PhotoKit transaction per target album.
        let grouped = Dictionary(grouping: usable) { assignment in
            if let identifier = assignment.albumIdentifier {
                return "existing:\(identifier)"
            }
            return "new:\(assignment.albumTitle)"
        }

        var applied: [String] = []
        var failed: [String] = []
        var messages: [String] = []

        for (_, group) in grouped {
            guard let first = group.first else { continue }
            var createdCollection: PHAssetCollection?
            var createdAlbumPersisted = false
            do {
                // Resolve every asset before creating a new album.  PhotoKit
                // does not expose a change request that can add assets to a
                // collection placeholder in the same transaction as
                // creation, so this preflight prevents an empty album when a
                // source asset has disappeared or is no longer accessible.
                let assets = fetchAssets(with: group.map(\.assetIdentifier))
                guard assets.count == group.count else {
                    throw AlbumOperationError.assetsUnavailable(first.albumTitle)
                }

                let collection: PHAssetCollection
                if let albumIdentifier = first.albumIdentifier {
                    guard let existing = fetchCollection(with: albumIdentifier),
                          existing.assetCollectionType == .album,
                          existing.assetCollectionSubtype == .albumRegular,
                          existing.canPerform(.addContent) else {
                        throw AlbumOperationError.collectionUnavailable(first.albumTitle)
                    }
                    collection = existing
                } else {
                    let sameNamedAlbums = matchingAlbums(named: first.albumTitle)
                    if let baseline = first.albumCreationBaselineIdentifiers {
                        let oldIdentifiers = Set(baseline)
                        guard !sameNamedAlbums.contains(where: {
                            !oldIdentifiers.contains($0.localIdentifier)
                        }) else {
                            throw AlbumOperationError.creationNeedsReview(first.albumTitle)
                        }
                    } else {
                        guard onAlbumCreationIntent(
                            first.albumTitle,
                            group.map(\.assetIdentifier),
                            sameNamedAlbums.map(\.localIdentifier)
                        ) else {
                            throw AlbumOperationError.localProgressUnavailable(first.albumTitle)
                        }
                    }
                    let createdIdentifier = try await createAlbum(title: first.albumTitle)
                    guard let created = fetchCollection(with: createdIdentifier) else {
                        throw AlbumOperationError.collectionUnavailable(first.albumTitle)
                    }
                    createdCollection = created
                    guard onCreatedAlbum(
                        createdIdentifier,
                        first.albumTitle,
                        group.map(\.assetIdentifier)
                    ) else {
                        throw AlbumOperationError.localProgressUnavailable(first.albumTitle)
                    }
                    createdAlbumPersisted = true
                    collection = created
                }

                try await add(assets, to: collection)
                let confirmed = confirmedMembership(of: assets, in: collection)
                applied.append(contentsOf: confirmed)
                let missing = Set(assets.map(\.localIdentifier)).subtracting(confirmed)
                if !missing.isEmpty {
                    failed.append(contentsOf: missing)
                    messages.append(String(localized: "照片相簿尚未显示 \(missing.count) 张已整理的照片；本地待办会保留。"))
                }
            } catch {
                if let createdCollection, !createdAlbumPersisted {
                    // The new identifier could not be saved locally, so no
                    // asset has been added. Remove the temporary empty album.
                    await deleteIfEmpty(createdCollection)
                }
                let identifiers = Set(group.map(\.assetIdentifier))
                let alreadyApplied = Set(applied)
                failed.append(contentsOf: identifiers.subtracting(alreadyApplied))
                messages.append(PhotosFailureMessage.message(for: error))
            }
        }

        let uniqueApplied = Array(Set(applied)).sorted()
        let uniqueFailed = Array(Set(failed).subtracting(uniqueApplied)).sorted()
        return PhotoAlbumApplyResult(
            appliedIdentifiers: uniqueApplied,
            failedIdentifiers: uniqueFailed,
            errorMessage: messages.isEmpty ? nil : messages.joined(separator: "\n")
        )
    }

    private func createAlbum(title: String) async throws -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw AlbumOperationError.invalidTitle
        }

        var placeholderIdentifier: String?
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: trimmedTitle)
            placeholderIdentifier = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderIdentifier else {
            throw AlbumOperationError.collectionUnavailable(trimmedTitle)
        }
        return placeholderIdentifier
    }

    private func add(_ assets: [PHAsset], to collection: PHAssetCollection) async throws {
        guard !assets.isEmpty else { return }
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else {
                return
            }
            request.addAssets(assets as NSArray)
        }
    }

    private func confirmedMembership(of assets: [PHAsset], in collection: PHAssetCollection) -> [String] {
        var remaining = Set(assets.map(\.localIdentifier))
        var confirmed: [String] = []
        let result = PHAsset.fetchAssets(in: collection, options: nil)
        result.enumerateObjects { asset, _, stop in
            if remaining.remove(asset.localIdentifier) != nil {
                confirmed.append(asset.localIdentifier)
                if remaining.isEmpty { stop.pointee = true }
            }
        }
        return confirmed
    }

    private func deleteIfEmpty(_ collection: PHAssetCollection) async {
        guard PHAsset.fetchAssets(in: collection, options: nil).count == 0 else { return }
        do {
            try await performChanges {
                PHAssetCollectionChangeRequest.deleteAssetCollections([collection] as NSArray)
            }
        } catch {
            // Keep the original add failure as the user-facing error.  The
            // pending assignment remains available for another attempt.
        }
    }

    private func fetchCollection(with identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        ).firstObject
    }

    private func matchingAlbums(named title: String) -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var matches: [PHAssetCollection] = []
        for index in 0..<result.count {
            let album = result.object(at: index)
            if album.localizedTitle == title {
                matches.append(album)
            }
        }
        return matches
    }

    private func fetchAssets(with identifiers: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        let byIdentifier = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        return identifiers.compactMap { byIdentifier[$0] }
    }

    private func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            photoLibrary.performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? AlbumOperationError.changeFailed)
                }
            }
        }
    }

    private static func canRead(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    private enum AlbumOperationError: LocalizedError {
        case invalidTitle
        case collectionUnavailable(String)
        case assetsUnavailable(String)
        case localProgressUnavailable(String)
        case creationNeedsReview(String)
        case changeFailed
        case assetUnavailable
        case albumUnavailable
        case removalNotAllowed
        case removalUnconfirmed
        case additionUnconfirmed

        var errorDescription: String? {
            switch self {
            case .invalidTitle:
                String(localized: "请输入相簿名称。")
            case .collectionUnavailable(let title):
                String(localized: "相簿“\(title)”已经不可用，待整理记录仍会保留。")
            case .assetsUnavailable(let title):
                String(localized: "无法将照片加入“\(title)”，待整理记录仍会保留。")
            case .localProgressUnavailable(let title):
                String(localized: "无法保存新相簿“\(title)”的进度，照片尚未加入相簿。")
            case .creationNeedsReview(let title):
                String(localized: "检测到新出现的同名相簿“\(title)”。请返回照片审核页，重新选择这个已有相簿后再确认，避免重复创建。")
            case .changeFailed:
                String(localized: "系统照片相簿修改失败，待整理记录仍会保留。")
            case .assetUnavailable:
                String(localized: "这张照片已无法访问，未从相簿移除。")
            case .albumUnavailable:
                String(localized: "这个相簿已不可用，照片没有被修改。")
            case .removalNotAllowed:
                String(localized: "系统不允许从这个相簿移除照片。")
            case .removalUnconfirmed:
                String(localized: "尚未确认照片已从相簿移除，请在系统照片中检查。")
            case .additionUnconfirmed:
                String(localized: "尚未确认照片已加入相簿，请在系统照片中检查。")
            }
        }
    }
}
