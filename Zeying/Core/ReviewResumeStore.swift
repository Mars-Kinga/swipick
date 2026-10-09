import Foundation
import Observation

enum ReviewQueueSortMode: String, Codable {
    case chronological
    case random
    case shuffled
}

enum ReviewQueueOrdering {
    static func shuffled(_ remaining: [String]) -> [String] {
        guard remaining.count > 1 else { return remaining }
        var result = remaining.shuffled()
        if result.first == remaining.first { result.swapAt(0, 1) }
        return result
    }

    static func restored(_ remaining: [String], originalOrder: [String]) -> [String] {
        let remainingIDs = Set(remaining)
        let restored = originalOrder.filter { remainingIDs.contains($0) }
        guard restored.count != remaining.count else { return restored }
        let restoredIDs = Set(restored)
        return restored + remaining.filter { !restoredIDs.contains($0) }
    }
}

struct ReviewQueueResume {
    let assetIDs: [String]
    let position: Int
    let sortMode: ReviewQueueSortMode
    var currentAssetID: String? {
        assetIDs.indices.contains(position) ? assetIDs[position] : nil
    }
}

@MainActor
@Observable
final class ReviewResumeStore {
    private static let legacyMonthKey = "com.mars.zeying.lastReviewMonth.v1"
    private static let legacyScopeKey = "com.mars.zeying.lastReviewScope.v1"
    private static let monthKey = "com.mars.zeying.lastReviewMonth.v2"
    private static let scopeKey = "com.mars.zeying.lastReviewScope.v2"
    private static let queueKey = "com.mars.zeying.reviewQueue.v1"
    private static let cursorKey = "com.mars.zeying.reviewQueueCursor.v1"
    static let maximumSavedQueueCount = 20_000

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendarOverride: Calendar?
    @ObservationIgnored private let storageDirectory: URL
    private var monthComponents: YearMonth?
    private var storedScope: StoredScope?
    private var legacyMonth: Date?
    private var legacyScope: LibraryScope?
    @ObservationIgnored private var savedQueue: SavedQueue?
    @ObservationIgnored private var savedCursor: QueueCursor?
    private(set) var errorMessage: String?
    private var calendar: Calendar { calendarOverride ?? .current }

    var lastMonth: Date? {
        monthComponents.flatMap { $0.date(in: calendar) } ?? legacyMonth
    }
    var lastScope: LibraryScope? {
        storedScope?.scope(in: calendar) ?? legacyScope
    }

    init(defaults: UserDefaults = .standard, calendar: Calendar? = nil, storageDirectory: URL? = nil) {
        self.defaults = defaults
        self.calendarOverride = calendar
        self.storageDirectory = storageDirectory ?? URL.applicationSupportDirectory
            .appending(path: "ReviewQueues", directoryHint: .isDirectory)
        monthComponents = Self.decode(YearMonth.self, key: Self.monthKey, defaults: defaults)
        storedScope = Self.decode(StoredScope.self, key: Self.scopeKey, defaults: defaults)
        // v1 contains only an instant; never guess its original time zone.
        // Retain that exact date until the user chooses a group again.
        legacyMonth = (defaults.object(forKey: Self.legacyMonthKey) as? TimeInterval)
            .map(Date.init(timeIntervalSince1970:))
        legacyScope = Self.decode(LibraryScope.self, key: Self.legacyScopeKey, defaults: defaults)
        savedQueue = Self.decode(SavedQueue.self, key: Self.queueKey, defaults: defaults)
        savedCursor = Self.decode(QueueCursor.self, key: Self.cursorKey, defaults: defaults)
    }

    func remember(scope: LibraryScope, containing date: Date?) {
        guard scope != .later else { return }
        let nextScope = StoredScope(scope, calendar: calendar)
        if nextScope != storedScope, save(nextScope, key: Self.scopeKey) {
            storedScope = nextScope
            legacyScope = nil
            defaults.removeObject(forKey: Self.legacyScopeKey)
        }
        rememberMonth(containing: date)
    }

    func rememberMonth(containing date: Date?) {
        guard let date else { return }
        let nextMonth = YearMonth(date, calendar: calendar)
        guard nextMonth != monthComponents, save(nextMonth, key: Self.monthKey) else { return }
        monthComponents = nextMonth
        legacyMonth = nil
        defaults.removeObject(forKey: Self.legacyMonthKey)
    }

    /// Call only when loading or changing an order, not on each card.
    func rememberQueue(scope: LibraryScope, assetIDs: [String], position: Int, sortMode: ReviewQueueSortMode) {
        guard scope != .later else { return }
        var seen: Set<String> = []
        var uniqueIDs: [String] = []
        for identifier in assetIDs {
            if seen.insert(identifier).inserted { uniqueIDs.append(identifier) }
        }
        let overflow = Array(uniqueIDs.dropFirst(Self.maximumSavedQueueCount))
        let queue = SavedQueue(
            id: UUID(), scope: StoredScope(scope, calendar: calendar),
            assetIDs: Array(uniqueIDs.prefix(Self.maximumSavedQueueCount)),
            sortMode: sortMode, hasOverflow: !overflow.isEmpty
        )
        // A large library keeps its complete order on disk while the small
        // preferences snapshot remains bounded. Neither is rewritten per card.
        if !overflow.isEmpty {
            do {
                try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(overflow).write(to: overflowURL(for: queue), options: .atomic)
            } catch {
                errorMessage = String(localized: "无法保存本组顺序；本次仍可继续整理，下次可能需要重新排序。")
                return
            }
        }
        guard save(queue, key: Self.queueKey) else { return }
        if let previous = savedQueue, previous.hasOverflow == true {
            try? FileManager.default.removeItem(at: overflowURL(for: previous))
        }
        savedQueue = queue
        errorMessage = nil
        let currentID = assetIDs.indices.contains(position) ? assetIDs[position] : nil
        writeCursor(queue: queue, position: max(position, 0), currentAssetID: currentID)
        remember(scope: scope, containing: nil)
    }

    /// The identifier array is untouched; only a small cursor is written.
    func updateQueuePosition(scope: LibraryScope, position: Int, currentAssetID: String?) {
        guard scope != .later, let queue = savedQueue,
              queue.scope == StoredScope(scope, calendar: calendar) else { return }
        writeCursor(queue: queue, position: max(position, 0), currentAssetID: currentAssetID)
    }

    /// Keeps the saved order, filters inaccessible/reviewed IDs, then appends
    /// new items. Start at the first remaining item so an undone choice is
    /// never skipped merely because it preceded the stored cursor.
    func restoredQueue(scope: LibraryScope, availableAssetIDs: [String], reviewedAssetIDs: Set<String>) -> ReviewQueueResume? {
        guard scope != .later, let queue = savedQueue,
              queue.scope == StoredScope(scope, calendar: calendar) else { return nil }
        let available = Set(availableAssetIDs)
        var seen: Set<String> = []
        var identifiers: [String] = []
        identifiers.reserveCapacity(available.count)
        let overflow = queue.hasOverflow == true
            ? (try? Data(contentsOf: overflowURL(for: queue)))
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            : []
        for identifier in queue.assetIDs + overflow {
            guard available.contains(identifier), !reviewedAssetIDs.contains(identifier),
                  seen.insert(identifier).inserted else { continue }
            identifiers.append(identifier)
        }
        // The persisted snapshot is bounded, but the live queue remains full.
        for identifier in availableAssetIDs {
            guard !reviewedAssetIDs.contains(identifier), seen.insert(identifier).inserted else { continue }
            identifiers.append(identifier)
        }
        return ReviewQueueResume(assetIDs: identifiers, position: 0, sortMode: queue.sortMode)
    }

    private func writeCursor(queue: SavedQueue, position: Int, currentAssetID: String?) {
        let cursor = QueueCursor(queueID: queue.id, position: position, currentAssetID: currentAssetID)
        guard cursor != savedCursor, save(cursor, key: Self.cursorKey) else { return }
        savedCursor = cursor
    }

    private func overflowURL(for queue: SavedQueue) -> URL {
        storageDirectory.appending(path: "\(queue.id.uuidString).json")
    }

    private func save<Value: Encodable>(_ value: Value, key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
    private static func decode<Value: Decodable>(_ type: Value.Type, key: String, defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private struct YearMonth: Codable, Equatable {
        let era: Int
        let year: Int
        let month: Int
        init(_ date: Date, calendar: Calendar) {
            era = calendar.component(.era, from: date)
            year = calendar.component(.year, from: date)
            month = calendar.component(.month, from: date)
        }
        func date(in calendar: Calendar) -> Date? {
            calendar.date(from: DateComponents(era: era, year: year, month: month, day: 1))
        }
    }
    private enum StoredScope: Codable, Equatable {
        case month(YearMonth)
        case year(era: Int, year: Int)
        case other(LibraryScope)
        init(_ scope: LibraryScope, calendar: Calendar) {
            switch scope {
            case .month(let date): self = .month(YearMonth(date, calendar: calendar))
            case .year(let date): self = .year(era: calendar.component(.era, from: date), year: calendar.component(.year, from: date))
            default: self = .other(scope)
            }
        }
        func scope(in calendar: Calendar) -> LibraryScope? {
            switch self {
            case .month(let components): return components.date(in: calendar).map(LibraryScope.month)
            case .year(let era, let year): return calendar.date(from: DateComponents(era: era, year: year, month: 1, day: 1)).map(LibraryScope.year)
            case .other(let scope): return scope
            }
        }
    }
    private struct SavedQueue: Codable {
        let id: UUID
        let scope: StoredScope
        let assetIDs: [String]
        let sortMode: ReviewQueueSortMode
        let hasOverflow: Bool?
    }
    private struct QueueCursor: Codable, Equatable {
        let queueID: UUID
        let position: Int
        let currentAssetID: String?
    }
}
