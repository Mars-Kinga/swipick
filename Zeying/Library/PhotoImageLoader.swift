import Foundation
@preconcurrency import Photos
import UIKit

enum PhotoImageLoader {
    @concurrent
    static func load(
        identifier: String, targetSize: CGSize, allowNetwork: Bool,
        contentMode: PHImageContentMode,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        timeout: Duration? = .seconds(5),
        onDegraded: (@MainActor (UIImage) -> Void)? = nil
    ) async -> UIImage? {
        guard !Task.isCancelled,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              !Task.isCancelled else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = deliveryMode == .highQualityFormat ? .exact : .fast
        options.isNetworkAccessAllowed = allowNetwork
        let manager = PHImageManager.default()
        let request = OneShotContinuation<UIImage?>(cancellationValue: nil)
        let deadline = timeout.map { duration in
            Task {
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                request.finishEarly(returning: nil, using: manager)
            }
        }
        defer { deadline?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let id = manager.requestImage(for: asset, targetSize: targetSize,
                    contentMode: contentMode, options: options) { image, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    let cloudOnly = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                    if cancelled || info?[PHImageErrorKey] != nil {
                        request.resume(returning: nil)
                    } else if degraded {
                        if let image {
                            if let onDegraded { Task { @MainActor in onDegraded(image) } }
                            if deliveryMode != .highQualityFormat {
                                request.finishEarly(returning: image, using: manager)
                            }
                        } else if !allowNetwork {
                            request.resume(returning: nil)
                        }
                    } else if !allowNetwork && cloudOnly && image == nil {
                        request.resume(returning: nil)
                    } else {
                        request.resume(returning: image)
                    }
                }
                request.install(requestID: id, manager: manager)
            }
        } onCancel: {
            request.cancel(using: manager)
        }
    }
}
