import Foundation
import Observation

/// Preferences that affect interaction feedback across the app.
///
/// The object is intentionally small and observable so every screen can read
/// the same setting without creating its own copy. UserDefaults is injected
/// for deterministic tests and kept out of the observable state.
@MainActor
@Observable
final class AppSettings {
    private static let hapticsEnabledKey = "com.mars.zeying.hapticsEnabled"

    @ObservationIgnored private let defaults: UserDefaults

    var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: Self.hapticsEnabledKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Older versions exposed a per-photo delete mode. Retire its saved
        // preference so an upgrade always uses the list-first flow.
        defaults.removeObject(forKey: "com.mars.zeying.directDeleteEnabled")
        if defaults.object(forKey: Self.hapticsEnabledKey) == nil {
            hapticsEnabled = true
        } else {
            hapticsEnabled = defaults.bool(forKey: Self.hapticsEnabledKey)
        }

    }
}
