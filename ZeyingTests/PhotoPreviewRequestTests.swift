import Foundation
@preconcurrency import Photos
import Testing
@testable import Zeying

struct PhotoPreviewRequestTests {
    @Test("取消先于请求 ID 返回时，结束等待并取消稍后注册的请求")
    func cancellationBeforeRequestRegistration() async {
        let manager = CancellationRecordingImageManager()
        let request = OneShotContinuation<Int?>(cancellationValue: nil)
        let value: Int? = await withCheckedContinuation { continuation in
            #expect(request.install(continuation))
            request.cancel(using: manager)
            request.install(requestID: 7, manager: manager)
            request.resume(returning: 42)
        }
        #expect(value == nil)
        #expect(manager.cancelledRequests == [7])
    }

    @Test("超时结束本地加载后，忽略迟到回调并只取消一次")
    func timeoutIgnoresLateResult() async {
        let manager = CancellationRecordingImageManager()
        let request = OneShotContinuation<Int?>(cancellationValue: nil)
        let value: Int? = await withCheckedContinuation { continuation in
            #expect(request.install(continuation))
            request.install(requestID: 9, manager: manager)
            request.finishEarly(returning: nil, using: manager)
            request.resume(returning: 42)
            request.cancel(using: manager)
        }
        #expect(value == nil)
        #expect(manager.cancelledRequests == [9])
    }

    @Test("开始等待前取消也能立即结束，不遗留 continuation")
    func cancellationBeforeContinuation() async {
        let manager = CancellationRecordingImageManager()
        let request = OneShotContinuation<Int?>(cancellationValue: nil)
        request.cancel(using: manager)
        let value: Int? = await withCheckedContinuation { continuation in
            #expect(!request.install(continuation))
        }
        #expect(value == nil)
    }
}

private final class CancellationRecordingImageManager: PHImageManager, @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [PHImageRequestID] = []

    var cancelledRequests: [PHImageRequestID] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    override func cancelImageRequest(_ requestID: PHImageRequestID) {
        lock.lock()
        identifiers.append(requestID)
        lock.unlock()
    }
}
