import Foundation
import Observation

/// Remembers which library entry the user last reviewed. Decisions remain in
/// ReviewStore; this only chooses where "Continue" starts.
@MainActor
@Observable
final class ReviewResumeStore {
    private static let lastMonthKey = "com.mars.zeying.lastReviewMonth.v1"
    private static let lastScopeKey = "com.mars.zeying.lastReviewScope.v1"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var lastMonth: Date?
    private(set) var lastScope: LibraryScope?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let timestamp = defaults.object(forKey: Self.lastMonthKey) as? TimeInterval {
            lastMonth = Date(timeIntervalSince1970: timestamp)
        } else {
            lastMonth = nil
        }
        lastScope = defaults.data(forKey: Self.lastScopeKey)
            .flatMap { try? JSONDecoder().decode(LibraryScope.self, from: $0) }
    }

    func remember(scope: LibraryScope, containing date: Date?) {
        guard scope != .later else { return }
        let normalizedScope: LibraryScope
        if case .month(let month) = scope,
           let normalizedMonth = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: month)
           ) {
            normalizedScope = .month(normalizedMonth)
        } else if case .year(let year) = scope,
                  let normalizedYear = Calendar.current.date(
                    from: Calendar.current.dateComponents([.year], from: year)
                  ) {
            normalizedScope = .year(normalizedYear)
        } else {
            normalizedScope = scope
        }

        if normalizedScope != lastScope,
           let data = try? JSONEncoder().encode(normalizedScope) {
            defaults.set(data, forKey: Self.lastScopeKey)
            lastScope = normalizedScope
        }
        rememberMonth(containing: date)
    }

    func rememberMonth(containing date: Date?) {
        guard let date,
              let month = Calendar.current.date(
                from: Calendar.current.dateComponents([.year, .month], from: date)
              ), month != lastMonth else {
            return
        }
        defaults.set(month.timeIntervalSince1970, forKey: Self.lastMonthKey)
        lastMonth = month
    }
}
