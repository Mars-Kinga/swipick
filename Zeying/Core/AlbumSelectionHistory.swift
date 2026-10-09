import Foundation

struct PhotoAlbumOption: Identifiable, Hashable {
    let id: String
    let title: String
    /// PhotoKit can report an unavailable estimate; refreshing must not scan
    /// every album just to calculate its size.
    let count: Int?
}

/// Counts a choice when it is saved locally, rather than waiting for the
/// final PhotoKit write. The existing key preserves previously recorded use.
@MainActor
final class AlbumSelectionHistory {
    private static let countsKey = "com.mars.zeying.albumSelectionCounts.v1"
    private static let pendingImportKey = "com.mars.zeying.albumSelectionPendingImport.v1"
    private let defaults: UserDefaults
    private var counts: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        counts = defaults.dictionary(forKey: Self.countsKey) as? [String: Int] ?? [:]
    }

    func recordSelection(of identifier: String) {
        guard !identifier.isEmpty else { return }
        counts[identifier, default: 0] += 1
        defaults.set(counts, forKey: Self.countsKey)
    }

    /// Older versions counted only confirmed writes. Recover still-pending
    /// choices once, using a floor so existing history is not counted twice.
    func importPendingSelectionsIfNeeded(_ identifiers: [String]) {
        guard !defaults.bool(forKey: Self.pendingImportKey) else { return }
        let pendingCounts = identifiers.reduce(into: [String: Int]()) { result, identifier in
            guard !identifier.isEmpty else { return }
            result[identifier, default: 0] += 1
        }
        for (identifier, count) in pendingCounts {
            counts[identifier] = max(counts[identifier, default: 0], count)
        }
        defaults.set(counts, forKey: Self.countsKey)
        defaults.set(true, forKey: Self.pendingImportKey)
    }

    func ordered(
        _ albums: [PhotoAlbumOption],
        newlyCreatedIdentifier: String? = nil
    ) -> [PhotoAlbumOption] {
        albums.sorted { left, right in
            if left.id != right.id {
                if left.id == newlyCreatedIdentifier { return true }
                if right.id == newlyCreatedIdentifier { return false }
            }
            let leftCount = counts[left.id, default: 0]
            let rightCount = counts[right.id, default: 0]
            if leftCount != rightCount { return leftCount > rightCount }
            let ordering = left.title.localizedStandardCompare(right.title)
            return ordering == .orderedSame ? left.id < right.id : ordering == .orderedAscending
        }
    }
}
