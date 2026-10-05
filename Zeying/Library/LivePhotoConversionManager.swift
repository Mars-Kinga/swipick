import Foundation
import Observation
@preconcurrency import Photos
import UniformTypeIdentifiers

struct LivePhotoConversion: Codable, Identifiable {
    enum Phase: String, Codable {
        case preparing
        case awaitingOriginalDeletion
        case originalDeleted
    }

    let sourceIdentifier: String
    let token: UUID
    let startedAt: Date
    let creationDate: Date
    let sourceModificationDate: Date?
    let albumIdentifiers: [String]
    var stillIdentifier: String?
    var phase: Phase

    var id: String { sourceIdentifier }
}

enum LivePhotoConversionError: LocalizedError {
    case fullAccessRequired
    case originalUnavailable
    case originalChanged
    case exportFailed(String)
    case creationFailed(String)
    case copyUnverified(String)
    case conversionMissing
    case operationAlreadyRunning
    case journalUnreadable

    var errorDescription: String? {
        switch self {
        case .fullAccessRequired:
            String(localized: "为确保保留原有相簿信息，转为静态照片需要完整照片访问权限。")
        case .originalUnavailable:
            String(localized: "无法找到原实况照片；没有删除任何照片。")
        case .originalChanged:
            String(localized: "原实况照片在创建副本后被修改。请先检查两张照片，再决定是否删除原件。")
        case .exportFailed(let detail):
            String(localized: "无法导出当前显示的静态画面：\(detail)")
        case .creationFailed(let detail):
            String(localized: "无法创建静态照片：\(detail)")
        case .copyUnverified(let detail):
            String(localized: "静态副本尚未通过核对：\(detail)。原实况照片仍然保留。")
        case .conversionMissing:
            String(localized: "找不到尚未完成的静态转换。")
        case .operationAlreadyRunning:
            String(localized: "这张照片正在转换，请稍候。")
        case .journalUnreadable:
            String(localized: "静态转换记录暂时无法读取。照片不会被自动删除；请保留 App 数据并检查系统照片中的原件与副本。")
        }
    }
}

/// A small persistent journal is kept outside PhotoKit. Every destructive
/// step checks the new still in Photos first, and a failed step leaves the
/// journal available for a later retry.
@MainActor
@Observable
final class LivePhotoConversionManager {
    static let shared = LivePhotoConversionManager()

    private static let journalKey = "com.mars.zeying.liveConversionJournal.v1"
    private static let completedKey = "com.mars.zeying.completedLiveConversions.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var completedIdentifiers: Set<String>
    private(set) var pending: [String: LivePhotoConversion]
    private(set) var convertedCount: Int
    private(set) var journalError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.journalKey) {
            do {
                pending = try JSONDecoder().decode([String: LivePhotoConversion].self, from: data)
                journalError = nil
            } catch {
                pending = [:]
                journalError = LivePhotoConversionError.journalUnreadable.localizedDescription
            }
        } else {
            pending = [:]
            journalError = nil
        }
        completedIdentifiers = defaults.data(forKey: Self.completedKey)
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }
            ?? []
        convertedCount = completedIdentifiers.count
    }

    var pendingConversions: [LivePhotoConversion] {
        pending.values.sorted { $0.creationDate > $1.creationDate }
    }

    func conversion(for sourceIdentifier: String) -> LivePhotoConversion? {
        pending[sourceIdentifier]
    }

    func prepare(asset: PHAsset, library: PhotoLibraryService) async throws -> LivePhotoConversion {
        try requireReadableJournal()
        try requireFullAccess()
        let sourceIdentifier = asset.localIdentifier
        guard inFlight.insert(sourceIdentifier).inserted else {
            throw LivePhotoConversionError.operationAlreadyRunning
        }
        defer { inFlight.remove(sourceIdentifier) }

        if var existing = pending[sourceIdentifier] {
            if existing.stillIdentifier == nil,
               let recovered = await Self.findStill(with: existing.token, date: existing.creationDate) {
                existing.stillIdentifier = recovered
                existing.phase = .awaitingOriginalDeletion
                try store(existing)
            }
            if let stillIdentifier = existing.stillIdentifier,
               Self.fetchAsset(stillIdentifier) == nil,
               existing.phase != .originalDeleted {
                try remove(sourceIdentifier)
            } else if existing.stillIdentifier != nil {
                try verify(existing, requireOriginal: existing.phase != .originalDeleted)
                return existing
            } else {
                guard Date().timeIntervalSince(existing.startedAt) > 30 else {
                    throw LivePhotoConversionError.creationFailed(String(localized: "系统可能仍在导入副本，请稍后再试"))
                }
                // The earlier creation never produced an accessible still.
                // The unique filename lets recovery find it after a restart.
                try remove(sourceIdentifier)
            }
        }

        guard let original = Self.fetchAsset(sourceIdentifier),
              original.mediaSubtypes.contains(.photoLive),
              let creationDate = original.creationDate else {
            throw LivePhotoConversionError.originalUnavailable
        }
        let albums = try Self.editableAlbums(containing: original)
        let token = UUID()
        var record = LivePhotoConversion(
            sourceIdentifier: sourceIdentifier,
            token: token,
            startedAt: .now,
            creationDate: creationDate,
            sourceModificationDate: original.modificationDate,
            albumIdentifiers: albums.map(\.localIdentifier),
            stillIdentifier: nil,
            phase: .preparing
        )
        try store(record)

        let exported: ExportedStill
        do {
            exported = try await Self.exportCurrentStill(for: original)
        } catch {
            try? remove(sourceIdentifier)
            throw LivePhotoConversionError.exportFailed(error.localizedDescription)
        }
        if Task.isCancelled {
            try? remove(sourceIdentifier)
            throw CancellationError()
        }
        guard let typeIdentifier = exported.typeIdentifier,
              let contentType = UTType(typeIdentifier),
              let fileExtension = contentType.preferredFilenameExtension else {
            try? remove(sourceIdentifier)
            throw LivePhotoConversionError.exportFailed(String(localized: "无法识别静态画面的文件格式"))
        }
        let filename = "ZeyingStill-\(token.uuidString).\(fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try await Task.detached(priority: .utility) {
                try exported.data.write(to: fileURL, options: .atomic)
            }.value
        } catch {
            try? remove(sourceIdentifier)
            throw LivePhotoConversionError.exportFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let newIdentifier = LockedCreatedIdentifier()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = creationDate
                request.location = original.location
                request.isFavorite = original.isFavorite
                request.isHidden = original.isHidden

                let resourceOptions = PHAssetResourceCreationOptions()
                resourceOptions.originalFilename = filename
                resourceOptions.contentType = contentType
                resourceOptions.shouldMoveFile = true
                request.addResource(with: .photo, fileURL: fileURL, options: resourceOptions)
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                newIdentifier.set(placeholder.localIdentifier)
                for album in albums {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            // Leave the token in the journal. If Photos imported the asset
            // despite an interrupted callback, recovery can find its filename.
            throw LivePhotoConversionError.creationFailed(error.localizedDescription)
        }

        guard let stillIdentifier = newIdentifier.value else {
            throw LivePhotoConversionError.creationFailed(String(localized: "系统没有返回新照片的标识"))
        }
        record.stillIdentifier = stillIdentifier
        record.phase = .awaitingOriginalDeletion
        try store(record)
        // Verification fetches the newly created asset directly. The normal
        // library snapshot refresh happens after deletion (or on recovery),
        // avoiding a full-library scan between the two conversion steps.
        try verify(record, requireOriginal: true)
        return record
    }

    func deleteOriginal(
        sourceIdentifier: String,
        library: PhotoLibraryService,
        reviews: ReviewStore,
        albumAssignments: PendingAlbumAssignmentStore
    ) async throws {
        try requireReadableJournal()
        try requireFullAccess()
        guard inFlight.insert(sourceIdentifier).inserted else {
            throw LivePhotoConversionError.operationAlreadyRunning
        }
        defer { inFlight.remove(sourceIdentifier) }
        guard var record = pending[sourceIdentifier], record.stillIdentifier != nil else {
            throw LivePhotoConversionError.conversionMissing
        }
        if record.phase != .originalDeleted,
           Self.fetchAsset(sourceIdentifier) == nil {
            // Full library access is required above, so absence here means
            // another actor has already removed the source. Keep the still.
            record.phase = .originalDeleted
            try store(record)
        }
        try verify(record, requireOriginal: record.phase != .originalDeleted)

        if record.phase != .originalDeleted {
            guard Self.fetchAsset(sourceIdentifier) != nil else {
                throw LivePhotoConversionError.originalUnavailable
            }
            let deleted = try await library.delete([sourceIdentifier])
            guard deleted.contains(sourceIdentifier) else {
                throw LivePhotoConversionError.originalUnavailable
            }
            record.phase = .originalDeleted
            try store(record)
        }
        try finishLocalState(record, reviews: reviews, albumAssignments: albumAssignments)
    }

    /// Offers a way to abandon the operation without leaving a duplicate.
    func deleteStillCopy(sourceIdentifier: String, library: PhotoLibraryService) async throws {
        try requireReadableJournal()
        try requireFullAccess()
        guard inFlight.insert(sourceIdentifier).inserted else {
            throw LivePhotoConversionError.operationAlreadyRunning
        }
        defer { inFlight.remove(sourceIdentifier) }
        guard let record = pending[sourceIdentifier],
              record.phase != .originalDeleted,
              let stillIdentifier = record.stillIdentifier else {
            throw LivePhotoConversionError.conversionMissing
        }
        guard let source = Self.fetchAsset(sourceIdentifier),
              source.mediaSubtypes.contains(.photoLive) else {
            throw LivePhotoConversionError.originalUnavailable
        }
        if Self.fetchAsset(stillIdentifier) != nil {
            let deleted = try await library.delete([stillIdentifier])
            guard deleted.contains(stillIdentifier) else {
                throw LivePhotoConversionError.copyUnverified(String(localized: "无法删除静态副本"))
            }
        }
        try remove(sourceIdentifier)
    }

    /// Repairs local review state if the app stopped after PhotoKit deleted
    /// the original but before SwiftData finished updating the identifiers.
    func reconcile(
        library: PhotoLibraryService,
        reviews: ReviewStore,
        albumAssignments: PendingAlbumAssignmentStore
    ) async {
        guard journalError == nil else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        for record in pendingConversions {
            if record.phase == .originalDeleted {
                try? finishLocalState(
                    record, reviews: reviews, albumAssignments: albumAssignments
                )
            } else if record.phase == .preparing,
                      let recovered = await Self.findStill(with: record.token, date: record.creationDate) {
                var updated = record
                updated.stillIdentifier = recovered
                updated.phase = .awaitingOriginalDeletion
                try? store(updated)
            }
        }
        await library.refresh()
    }

    private func finishLocalState(
        _ record: LivePhotoConversion,
        reviews: ReviewStore,
        albumAssignments: PendingAlbumAssignmentStore
    ) throws {
        guard let stillIdentifier = record.stillIdentifier,
              Self.fetchAsset(stillIdentifier) != nil else {
            throw LivePhotoConversionError.copyUnverified(String(localized: "找不到静态副本"))
        }
        guard albumAssignments.replaceAssetIdentifier(
            sourceIdentifier: record.sourceIdentifier,
            stillIdentifier: stillIdentifier
        ) else {
            throw LivePhotoConversionError.copyUnverified(
                albumAssignments.errorMessage ?? String(localized: "无法转移相簿待办")
            )
        }
        guard reviews.replaceLivePhotoRecord(sourceIdentifier: record.sourceIdentifier,
                                             stillIdentifier: stillIdentifier) else {
            throw LivePhotoConversionError.copyUnverified(reviews.errorMessage ?? String(localized: "无法更新本地处理记录"))
        }
        var updatedCompleted = completedIdentifiers
        if updatedCompleted.insert(record.sourceIdentifier).inserted {
            defaults.set(try JSONEncoder().encode(updatedCompleted), forKey: Self.completedKey)
            completedIdentifiers = updatedCompleted
            convertedCount = updatedCompleted.count
        }
        try remove(record.sourceIdentifier)
    }

    private func verify(_ record: LivePhotoConversion, requireOriginal: Bool) throws {
        guard let stillIdentifier = record.stillIdentifier,
              let still = Self.fetchAsset(stillIdentifier),
              still.mediaType == .image,
              !still.mediaSubtypes.contains(.photoLive),
              still.pixelWidth > 0, still.pixelHeight > 0 else {
            throw LivePhotoConversionError.copyUnverified(String(localized: "新照片不存在或仍是实况照片"))
        }
        guard let date = still.creationDate,
              abs(date.timeIntervalSince(record.creationDate)) < 1 else {
            throw LivePhotoConversionError.copyUnverified(String(localized: "拍摄时间与原件不一致"))
        }
        if requireOriginal {
            guard let original = Self.fetchAsset(record.sourceIdentifier),
                  original.mediaSubtypes.contains(.photoLive) else {
                throw LivePhotoConversionError.originalUnavailable
            }
            guard original.modificationDate == record.sourceModificationDate else {
                throw LivePhotoConversionError.originalChanged
            }
        }
        if !record.albumIdentifiers.isEmpty {
            // Ask PhotoKit for the still's memberships once. Enumerating every
            // asset in each original album can block the review UI for a large
            // album even though we only need one membership check.
            let containingAlbums = PHAssetCollection.fetchAssetCollectionsContaining(
                still, with: .album, options: nil
            )
            var containingIdentifiers = Set<String>()
            for index in 0..<containingAlbums.count {
                containingIdentifiers.insert(containingAlbums.object(at: index).localIdentifier)
            }
            for identifier in record.albumIdentifiers where !containingIdentifiers.contains(identifier) {
                let album = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [identifier], options: nil
                ).firstObject
                throw LivePhotoConversionError.copyUnverified(
                    album == nil ? String(localized: "原相簿已不可用") : String(localized: "静态副本尚未加入原相簿")
                )
            }
        }
    }

    private func store(_ record: LivePhotoConversion) throws {
        var updated = pending
        updated[record.sourceIdentifier] = record
        try persist(updated)
    }

    private func remove(_ sourceIdentifier: String) throws {
        var updated = pending
        updated.removeValue(forKey: sourceIdentifier)
        try persist(updated)
    }

    private func persist(_ records: [String: LivePhotoConversion]) throws {
        try requireReadableJournal()
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: Self.journalKey)
        pending = records
    }

    private func requireFullAccess() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw LivePhotoConversionError.fullAccessRequired
        }
    }

    private func requireReadableJournal() throws {
        if journalError != nil { throw LivePhotoConversionError.journalUnreadable }
    }

    private static func fetchAsset(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    private static func editableAlbums(containing asset: PHAsset) throws -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollectionsContaining(
            asset, with: .album, options: nil
        )
        var albums: [PHAssetCollection] = []
        for index in 0..<result.count {
            let album = result.object(at: index)
            guard album.canPerform(.addContent) else {
                throw LivePhotoConversionError.creationFailed(String(localized: "原照片属于无法写入的相簿，暂不能安全转换"))
            }
            albums.append(album)
        }
        return albums
    }

    private static func findStill(with token: UUID, date: Date) async -> String? {
        await Task.detached(priority: .utility) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@",
                date.addingTimeInterval(-2) as NSDate,
                date.addingTimeInterval(2) as NSDate
            )
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            let filenamePrefix = "ZeyingStill-\(token.uuidString)."
            for index in 0..<assets.count {
                guard !Task.isCancelled else { return nil }
                let asset = assets.object(at: index)
                if PHAssetResource.assetResources(for: asset).contains(where: {
                    $0.originalFilename.hasPrefix(filenamePrefix)
                }) {
                    return asset.localIdentifier
                }
            }
            return nil
        }.value
    }

    private static func exportCurrentStill(for asset: PHAsset) async throws -> ExportedStill {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        let manager = PHImageManager.default()
        let state = StillImageRequestState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                let requestID = manager.requestImageDataAndOrientation(
                    for: asset, options: options
                ) { data, typeIdentifier, _, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    if let error = info?[PHImageErrorKey] as? Error {
                        state.finish(.failure(error))
                    } else if (info?[PHImageCancelledKey] as? Bool) == true {
                        state.finish(.failure(CancellationError()))
                    } else if let data, !data.isEmpty {
                        state.finish(.success(ExportedStill(data: data, typeIdentifier: typeIdentifier)))
                    } else {
                        state.finish(.failure(LivePhotoConversionError.exportFailed(String(localized: "系统没有返回图像数据"))))
                    }
                }
                state.install(requestID: requestID, manager: manager)
            }
        } onCancel: {
            state.cancel(using: manager)
        }
    }
}

private struct ExportedStill: Sendable {
    let data: Data
    let typeIdentifier: String?
}

private final class LockedCreatedIdentifier: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ identifier: String) {
        lock.lock()
        stored = identifier
        lock.unlock()
    }
}

private final class StillImageRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ExportedStill, Error>?
    private var requestID: PHImageRequestID?
    private var finished = false

    func install(_ continuation: CheckedContinuation<ExportedStill, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func install(requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = finished
        lock.unlock()
        if shouldCancel { manager.cancelImageRequest(requestID) }
    }

    func finish(_ result: Result<ExportedStill, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel(using manager: PHImageManager) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let requestID = self.requestID
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let requestID { manager.cancelImageRequest(requestID) }
        continuation?.resume(throwing: CancellationError())
    }
}
