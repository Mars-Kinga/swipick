import Foundation
@preconcurrency import Photos
import Testing
@testable import Zeying

struct PhotoShareTests {
    @Test("Live Photo selection keeps still and paired video on one resource version")
    func matchingLivePhotoResourceTypes() {
        let original = PhotoShareResourceSelection.livePhotoPairTypes(
            availableTypes: [.photo, .pairedVideo, .fullSizePhoto, .fullSizePairedVideo]
        )
        #expect(original?.photo == .photo)
        #expect(original?.pairedVideo == .pairedVideo)

        let edited = PhotoShareResourceSelection.livePhotoPairTypes(
            availableTypes: [.fullSizePhoto, .fullSizePairedVideo]
        )
        #expect(edited?.photo == .fullSizePhoto)
        #expect(edited?.pairedVideo == .fullSizePairedVideo)

        // A still from one version must not be combined with a paired video
        // from another version.
        #expect(PhotoShareResourceSelection.livePhotoPairTypes(
            availableTypes: [.photo, .fullSizePairedVideo]
        ) == nil)
    }

    @Test("Share payload cleanup removes files and its private export folder")
    func payloadCleanup() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeyingShareTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("photo.jpg")
        try Data([0x01, 0x02]).write(to: fileURL)

        let payload = PhotoSharePayload(
            items: [.file(fileURL)], temporaryURLs: [fileURL, folder]
        )
        payload.cleanup()

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("资源请求 ID 安装前取消仍结束等待并取消稍后注册的请求")
    func cancellationBeforeResourceRequestID() async throws {
        let fileURL = temporaryShareRequestFileURL()
        let request = try ShareResourceDataRequest(fileURL: fileURL)
        let manager = CancellationRecordingResourceManager()
        var receivedError: Error?

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                #expect(request.install(continuation))
                request.receive(Data([0x01, 0x02]))
                request.cancel(using: manager)
                request.install(requestID: 41, manager: manager)
                // A late PhotoKit callback must not recreate or append to the
                // temporary file after cancellation has completed.
                request.receive(Data([0x03]))
            }
        } catch {
            receivedError = error
        }

        #expect(receivedError is CancellationError)
        #expect(manager.cancelledRequests == [41])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("资源请求 ID 已安装时取消会取消底层请求并忽略迟到数据")
    func cancellationAfterResourceRequestID() async throws {
        let fileURL = temporaryShareRequestFileURL()
        let request = try ShareResourceDataRequest(fileURL: fileURL)
        let manager = CancellationRecordingResourceManager()
        var receivedError: Error?

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                #expect(request.install(continuation))
                request.install(requestID: 73, manager: manager)
                request.receive(Data([0x0A]))
                request.cancel(using: manager)
                request.receive(Data([0x0B]))
            }
        } catch {
            receivedError = error
        }

        #expect(receivedError is CancellationError)
        #expect(manager.cancelledRequests == [73])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}

private func temporaryShareRequestFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ZeyingShareRequest-\(UUID().uuidString).bin")
}

private final class CancellationRecordingResourceManager: PHAssetResourceManager, @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [PHAssetResourceDataRequestID] = []

    var cancelledRequests: [PHAssetResourceDataRequestID] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    override func cancelDataRequest(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        identifiers.append(requestID)
        lock.unlock()
    }
}
