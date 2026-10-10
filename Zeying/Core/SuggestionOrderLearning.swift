import Foundation

/// Only aggregate interactions are retained. No photo identifiers or images
/// enter the learned ordering, and it never changes a keep/delete decision.
struct SuggestionOrderLearning: Codable, Equatable, Sendable {
    struct Counts: Codable, Equatable, Sendable {
        var completed = 0
        var selective = 0
        var skipped = 0
    }

    private(set) var counts: [SuggestionReason: Counts] = [:]

    var hasHistory: Bool { counts.values.contains { $0.completed > 0 || $0.skipped > 0 } }

    mutating func recordCompletion(reason: SuggestionReason, kept: Int, total: Int) {
        guard total > 0, (0...total).contains(kept) else { return }
        var value = counts[reason] ?? Counts()
        value.completed += 1
        if kept < total { value.selective += 1 }
        counts[reason] = value
    }

    mutating func undoCompletion(reason: SuggestionReason, kept: Int, total: Int) {
        guard var value = counts[reason], value.completed > 0 else { return }
        value.completed -= 1
        if kept < total { value.selective = max(0, value.selective - 1) }
        if value.completed == 0 && value.skipped == 0 { counts.removeValue(forKey: reason) }
        else { counts[reason] = value }
    }

    mutating func recordSkip(reason: SuggestionReason) {
        var value = counts[reason] ?? Counts()
        value.skipped += 1
        counts[reason] = value
    }

    mutating func clearSkips() {
        for reason in Array(counts.keys) {
            counts[reason]?.skipped = 0
            if counts[reason]?.completed == 0 { counts.removeValue(forKey: reason) }
        }
    }

    /// Bayesian damping makes one tap nearly invisible; repeated behavior can
    /// move a reason by at most one category step.
    func score(for reason: SuggestionReason) -> Double {
        guard let value = counts[reason] else { return 0 }
        let signal = Double(value.completed) + Double(value.selective) * 0.5 - Double(value.skipped)
        let observations = Double(value.completed + value.skipped)
        return max(-0.8, min(0.8, signal / (6 + observations)))
    }
}
