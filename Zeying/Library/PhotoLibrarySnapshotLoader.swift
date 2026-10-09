import Foundation
@preconcurrency import Photos

struct LibraryTimeBucket: Identifiable {
    let date: Date
    let assets: [PHAsset]
    var id: Date { date }
}

struct AssetPreviewVersion: Equatable {
    let modifiedAt: Date?
    let width: Int
    let height: Int
    let mediaType: Int
    let subtypes: UInt
}

/// Immutable PhotoKit results and the indexes derived from them. A refresh
/// owns its snapshot; the UI never reads a partially constructed index.
struct PhotoLibrarySnapshot {
    let authorization: PHAuthorizationStatus
    let fetchResult: PHFetchResult<PHAsset>
    let albumFetchResults: [String: PHFetchResult<PHAsset>]
    let albumMembers: [String: [String]]
    let assets: [PHAsset]
    let assetsByIdentifier: [String: PHAsset]
    let albums: [LibraryAlbum]
    let scopedAssets: [LibraryScope: [PHAsset]]
    let months: [LibraryTimeBucket]
    let years: [LibraryTimeBucket]
    let suggestionAssets: [SuggestionAsset]
    let previewVersions: [String: AssetPreviewVersion]
    let snapshotFingerprint: Int
    let suggestionFingerprint: Int
}

enum PhotoLibrarySnapshotLoader {
    @concurrent
    static func load(previous: PhotoLibrarySnapshot?, changes: [PHChange]) async -> PhotoLibrarySnapshot? {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited, !Task.isCancelled else { return nil }
        let previous = previous?.authorization == authorization ? previous : nil
        let fetchResult: PHFetchResult<PHAsset>
        if let previous, !changes.isEmpty,
           !changes.contains(where: { $0.changeDetails(for: previous.fetchResult) != nil }) {
            fetchResult = previous.fetchResult
        } else {
            // Query the authoritative after-state once for a coalesced batch;
            // later PHChange objects need not describe an intermediate result.
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchResult = PHAsset.fetchAssets(with: options)
        }
        var assets: [PHAsset] = []
        var byID: [String: PHAsset] = [:]
        var entries: [LibraryIndexEntry] = []
        var suggestionAssets: [SuggestionAsset] = []
        var previewVersions: [String: AssetPreviewVersion] = [:]
        var snapshotHash = Hasher()
        var suggestionHash = Hasher()
        let calendar = Calendar.autoupdatingCurrent
        snapshotHash.combine(calendar.identifier)
        snapshotHash.combine(calendar.timeZone.identifier)
        assets.reserveCapacity(fetchResult.count)
        byID.reserveCapacity(fetchResult.count)
        for index in 0..<fetchResult.count {
            guard !Task.isCancelled else { return nil }
            let asset = fetchResult.object(at: index)
            let id = asset.localIdentifier
            let date = asset.creationDate
            let modified = asset.modificationDate
            let width = asset.pixelWidth
            let height = asset.pixelHeight
            let type = asset.mediaType
            let subtypes = asset.mediaSubtypes
            let favorite = asset.isFavorite
            let burst = asset.burstIdentifier
            assets.append(asset)
            byID[id] = asset
            previewVersions[id] = AssetPreviewVersion(modifiedAt: modified, width: width, height: height,
                mediaType: type.rawValue, subtypes: subtypes.rawValue)
            var categories: [MediaCategory] = []
            if type == .image { categories.append(.photo) }
            if type == .video { categories.append(.video) }
            if subtypes.contains(.photoScreenshot) { categories.append(.screenshot) }
            if subtypes.contains(.photoLive) { categories.append(.livePhoto) }
            if subtypes.contains(.videoScreenRecording) { categories.append(.screenRecording) }
            entries.append(LibraryIndexEntry(identifier: id, creationDate: date, categories: categories))
            snapshotHash.combine(id)
            snapshotHash.combine(date)
            snapshotHash.combine(modified)
            snapshotHash.combine(width)
            snapshotHash.combine(height)
            snapshotHash.combine(type.rawValue)
            snapshotHash.combine(subtypes.rawValue)
            snapshotHash.combine(favorite)
            snapshotHash.combine(burst)
            if type == .image {
                let descriptor = SuggestionAsset(id: id, modifiedAt: modified, createdAt: date,
                    width: width, height: height, isScreenshot: subtypes.contains(.photoScreenshot),
                    isLivePhoto: subtypes.contains(.photoLive), burstID: burst,
                    isProtected: favorite, isEligible: !favorite)
                suggestionAssets.append(descriptor)
                suggestionHash.combine(descriptor)
            }
        }
        let index = LibraryScopeIndex(entries: entries, calendar: calendar)
        var scoped = index.identifiersByScope.mapValues { $0.compactMap { byID[$0] } }
        var albums: [LibraryAlbum] = []
        var albumFetches: [String: PHFetchResult<PHAsset>] = [:]
        var albumMembers: [String: [String]] = [:]
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            for collectionIndex in 0..<collections.count {
                guard !Task.isCancelled else { return nil }
                let collection = collections.object(at: collectionIndex)
                guard collection.assetCollectionSubtype != .smartAlbumAllHidden else { continue }
                let id = collection.localIdentifier
                let fetched: PHFetchResult<PHAsset>
                let members: [String]
                if let oldFetch = previous?.albumFetchResults[id], !changes.isEmpty,
                   !changes.contains(where: { $0.changeDetails(for: oldFetch) != nil }),
                   let cached = previous?.albumMembers[id] {
                    fetched = oldFetch
                    members = cached.filter { byID[$0] != nil }
                } else {
                    let options = PHFetchOptions()
                    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    fetched = PHAsset.fetchAssets(in: collection, options: options)
                    members = identifiers(in: fetched, available: byID)
                }
                guard !Task.isCancelled else { return nil }
                albumFetches[id] = fetched
                albumMembers[id] = members
                scoped[.album(id)] = members.compactMap { byID[$0] }
                if collection.assetCollectionSubtype == .smartAlbumSelfPortraits {
                    scoped[.category(.selfie)] = members.compactMap { byID[$0] }
                }
                guard !members.isEmpty else { continue }
                var coverIdentifier = members.first
                if let keyAssets = PHAsset.fetchKeyAssets(in: collection, options: nil) {
                    for keyIndex in 0..<keyAssets.count {
                        let identifier = keyAssets.object(at: keyIndex).localIdentifier
                        if byID[identifier] != nil {
                            coverIdentifier = identifier
                            break
                        }
                    }
                }
                let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                albums.append(LibraryAlbum(id: id, title: title?.isEmpty == false ? title! : String(localized: "未命名相簿"),
                    count: members.count, coverAssetIdentifier: coverIdentifier,
                    smartSubtypeRawValue: type == .smartAlbum ? collection.assetCollectionSubtype.rawValue : nil))
            }
        }
        albums.sort {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return PhotoLibrarySnapshot(authorization: authorization, fetchResult: fetchResult,
            albumFetchResults: albumFetches, albumMembers: albumMembers, assets: assets,
            assetsByIdentifier: byID, albums: albums, scopedAssets: scoped,
            months: index.months.map { LibraryTimeBucket(date: $0, assets: scoped[.month($0)] ?? []) },
            years: index.years.map { LibraryTimeBucket(date: $0, assets: scoped[.year($0)] ?? []) },
            suggestionAssets: suggestionAssets, previewVersions: previewVersions,
            snapshotFingerprint: snapshotHash.finalize(), suggestionFingerprint: suggestionHash.finalize())
    }

    private static func identifiers(in result: PHFetchResult<PHAsset>, available: [String: PHAsset]) -> [String] {
        var identifiers: [String] = []
        identifiers.reserveCapacity(result.count)
        for index in 0..<result.count {
            guard !Task.isCancelled else { return [] }
            let id = result.object(at: index).localIdentifier
            if available[id] != nil { identifiers.append(id) }
        }
        return identifiers
    }
}
