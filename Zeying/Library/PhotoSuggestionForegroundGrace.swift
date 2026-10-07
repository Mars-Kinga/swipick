import UIKit

/// Finish the current small piece of local analysis when the app leaves the
/// foreground. iOS owns the expiration; the scheduled BGProcessing task can
/// resume later if the foreground allowance runs out.
@MainActor
enum PhotoSuggestionForegroundGrace {
    private static var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin(service: PhotoSuggestionService) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Photo Suggestions") {
            Task { @MainActor in
                service.pause()
                end()
            }
        }
    }

    static func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
