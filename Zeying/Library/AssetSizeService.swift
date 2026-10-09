import Foundation
import Observation
@preconcurrency import Photos

/// Resolves local image sizes without network access. An explicit request can
/// also read iCloud resources or large videos when the user asks for them.
@MainActor
@Observable
final class AssetSizeService {
    @ObservationIgnored private var cachedSizes: [String: CachedSize] = [:]
    @ObservationIgnored private var pendingLocalSizes: [String: LocalSizeRequest] = [:]

    init() {}

    /// Returns a cached size without asking PhotoKit for original metadata on
    /// the main queue. PhotoKit may synchronously fetch that metadata.
    func knownSize(for asset: PHAsset) -> Int64? {
        let identifier = asset.localIdentifier
        if let cachedSize = cachedSizes[identifier],
           cachedSize.modificationDate == asset.modificationDate {
            return cachedSize.bytes
        }
        return nil
    }

    /// Reads locally available image resources without downloading from
    /// iCloud. Streaming counts bytes without retaining the image in memory.
    /// Videos stay opt-in because automatically reading a large video would
    /// compete with preview playback and cause avoidable I/O stalls.
    func automaticLocalSize(for asset: PHAsset) async -> Int64? {
        if let size = knownSize(for: asset) { return size }
        guard !Task.isCancelled else { return nil }
        let identifier = asset.localIdentifier
        let request = localSizeRequest(for: asset)
        let size = await request.task.value
        if pendingLocalSizes[identifier]?.token == request.token {
            pendingLocalSizes.removeValue(forKey: identifier)
        }
        guard !Task.isCancelled, let size else { return nil }
        cachedSizes[identifier] = CachedSize(modificationDate: asset.modificationDate, bytes: size)
        return size
    }

    private func localSizeRequest(for asset: PHAsset) -> LocalSizeRequest {
        let identifier = asset.localIdentifier
        let modifiedAt = asset.modificationDate
        let isImage = asset.mediaType == .image
        if let pending = pendingLocalSizes[identifier], pending.modificationDate == modifiedAt {
            return pending
        }
        pendingLocalSizes[identifier]?.task.cancel()
        let request = LocalSizeRequest(
            modificationDate: modifiedAt,
            token: UUID(),
            task: Task.detached(priority: .background) {
                await AssetSizeLookup.measure(
                    identifier: identifier,
                    allowNetwork: false,
                    streamWhenMetadataIsUnknown: isImage
                )
            }
        )
        pendingLocalSizes[identifier] = request
        return request
    }

    /// Streams every resource for an asset and returns the sum of the bytes.
    /// This method is intentionally explicit because an iCloud-only resource
    /// may need to be downloaded to answer the question accurately.
    func fetchSize(for asset: PHAsset) async -> Int64? {
        if let knownSize = knownSize(for: asset) {
            return knownSize
        }
        guard !Task.isCancelled else { return nil }

        return await measuredSize(for: asset, allowNetwork: true, streamWhenMetadataIsUnknown: true)
    }

    private func measuredSize(
        for asset: PHAsset,
        allowNetwork: Bool,
        streamWhenMetadataIsUnknown: Bool
    ) async -> Int64? {
        guard !Task.isCancelled else { return nil }
        let identifier = asset.localIdentifier
        let worker = Task.detached(priority: .utility) {
            await AssetSizeLookup.measure(
                identifier: identifier,
                allowNetwork: allowNetwork,
                streamWhenMetadataIsUnknown: streamWhenMetadataIsUnknown
            )
        }
        let size = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, let size else { return nil }
        cachedSizes[identifier] = CachedSize(modificationDate: asset.modificationDate, bytes: size)
        return size
    }

    private struct CachedSize {
        let modificationDate: Date?
        let bytes: Int64
    }

    private struct LocalSizeRequest {
        let modificationDate: Date?
        let token: UUID
        let task: Task<Int64?, Never>
    }
}

/// Re-fetches by identifier so the PHAsset and its resources stay entirely on
/// the background executor. Only the resulting byte count crosses actors.
private enum AssetSizeLookup {
    static func measure(
        identifier: String,
        allowNetwork: Bool,
        streamWhenMetadataIsUnknown: Bool
    ) async -> Int64? {
        guard !Task.isCancelled,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return nil }

        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            // Do not present a partial total if one resource has no dataSize.
            let metadataSizes = resources.compactMap { resource -> Int64? in
                guard let dataSize = resource.dataSize else { return nil }
                return Int64(dataSize)
            }
            if metadataSizes.count == resources.count {
                return metadataSizes.reduce(Int64.zero, +)
            }
        }
        #endif

        guard streamWhenMetadataIsUnknown else { return nil }
        do {
            var total: Int64 = 0
            for resource in resources {
                try Task.checkCancellation()
                total += try await streamSize(for: resource, allowNetwork: allowNetwork)
            }
            try Task.checkCancellation()
            return total
        } catch {
            return nil
        }
    }

    private static func streamSize(for resource: PHAssetResource, allowNetwork: Bool) async throws -> Int64 {
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        let state = ResourceDataRequestState()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }

                let requestID = manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { data in
                        state.append(data.count)
                    },
                    completionHandler: { error in
                        if let error {
                            state.finish(.failure(error))
                        } else {
                            state.finish(.success(state.total))
                        }
                    }
                )
                state.install(requestID: requestID, manager: manager)
            }
        }, onCancel: {
            state.cancel(using: manager)
        })
    }

}

private final class ResourceDataRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID?
    private var continuation: CheckedContinuation<Int64, Error>?
    private var isFinished = false
    private var byteCount: Int64 = 0

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return byteCount
    }

    /// Installs the continuation. Returns false if cancellation won the race
    /// before the PhotoKit request was created.
    func install(_ continuation: CheckedContinuation<Int64, Error>) -> Bool {
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

    func append(_ count: Int) {
        lock.lock()
        if !isFinished {
            byteCount += Int64(count)
        }
        lock.unlock()
    }

    func install(requestID: PHAssetResourceDataRequestID, manager: PHAssetResourceManager) {
        lock.lock()
        self.requestID = requestID
        let shouldCancel = isFinished
        lock.unlock()

        if shouldCancel {
            manager.cancelDataRequest(requestID)
        }
    }

    func finish(_ result: Result<Int64, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
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
        continuation?.resume(throwing: CancellationError())
    }
}
