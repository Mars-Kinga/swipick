import SwiftUI
import UIKit
@preconcurrency import Photos
import PhotosUI

/// Presents the system share sheet for a PhotoKit export whose temporary
/// resources are owned by the presenting payload until the sheet is dismissed.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let payload: PhotoSharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let itemProviders = payload.items.compactMap { item -> NSItemProvider? in
            switch item {
            case .file(let url):
                return NSItemProvider(contentsOf: url)
            case .livePhoto(let livePhoto):
                // PHLivePhoto's Transferable representation keeps the still
                // and paired-video resources as one Live Photo item. The
                // payload keeps those original resource files alive until the
                // sheet closes.
                let provider = NSItemProvider()
                provider.register(livePhoto)
                return provider
            }
        }
        let configuration = UIActivityItemsConfiguration(itemProviders: itemProviders)
        // Keep the payload (and its resource URLs) attached to the system
        // configuration even if the SwiftUI sheet state is updated while the
        // native controller is still finishing a transfer.
        configuration.localObject = payload
        return UIActivityViewController(activityItemsConfiguration: configuration)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
