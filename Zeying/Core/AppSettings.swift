import Foundation
import Observation

/// Preferences shared across interaction and photo browsing.
///
/// The object is intentionally small and observable so every screen can read
/// the same setting without creating its own copy. UserDefaults is injected
/// for deterministic tests and kept out of the observable state.
@MainActor
@Observable
final class AppSettings {
    private static let hapticsEnabledKey = "com.mars.zeying.hapticsEnabled"
    private static let sideTapDecisionsKey = "com.mars.zeying.sideTapDecisionsEnabled"
    private static let protectFavoritesKey = "com.mars.zeying.protectFavoritesEnabled"
    private static let iCloudAutoDownloadKey = "com.mars.zeying.iCloudAutoDownloadEnabled"

    @ObservationIgnored private let defaults: UserDefaults

    var sideTapDecisionsEnabled: Bool {
        didSet { defaults.set(sideTapDecisionsEnabled, forKey: Self.sideTapDecisionsKey) }
    }

    var protectFavoritesEnabled: Bool {
        didSet { defaults.set(protectFavoritesEnabled, forKey: Self.protectFavoritesKey) }
    }

    var iCloudAutoDownloadEnabled: Bool {
        didSet { defaults.set(iCloudAutoDownloadEnabled, forKey: Self.iCloudAutoDownloadKey) }
    }

    var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: Self.hapticsEnabledKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sideTapDecisionsEnabled = defaults.bool(forKey: Self.sideTapDecisionsKey)
        protectFavoritesEnabled = defaults.object(forKey: Self.protectFavoritesKey) == nil
            ? true : defaults.bool(forKey: Self.protectFavoritesKey)
        iCloudAutoDownloadEnabled = defaults.bool(forKey: Self.iCloudAutoDownloadKey)
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
