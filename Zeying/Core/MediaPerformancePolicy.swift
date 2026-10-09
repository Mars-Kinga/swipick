import Foundation

struct ReviewPrefetchBudget: Equatable, Sendable {
    let highQualityCount: Int
    let quickCount: Int
    let videoCount: Int

    static func current(
        thermalState: ProcessInfo.ThermalState,
        lowPowerMode: Bool,
        memoryPressure: Bool
    ) -> Self {
        if memoryPressure || thermalState == .critical {
            return Self(highQualityCount: 0, quickCount: 1, videoCount: 0)
        }
        if lowPowerMode || thermalState == .fair || thermalState == .serious {
            return Self(highQualityCount: 1, quickCount: 2, videoCount: 0)
        }
        return Self(highQualityCount: 2, quickCount: 3, videoCount: 1)
    }
}

/// Bounded reuse without retaining observations for the entire photo library.
struct BoundedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var previous: Key?
        var next: Key?
    }
    let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var oldest: Key?
    private var newest: Key?
    var count: Int { entries.count }

    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        guard capacity > 0 else { return }
        if entries[key] != nil {
            entries[key]?.value = value
            touch(key)
            return
        }
        entries[key] = Entry(value: value, previous: newest, next: nil)
        if let newest { entries[newest]?.next = key }
        else { oldest = key }
        newest = key
        if entries.count > capacity, let evicted = oldest,
           let removed = entries.removeValue(forKey: evicted) {
            oldest = removed.next
            if let oldest { entries[oldest]?.previous = nil }
            else { newest = nil }
        }
    }

    private mutating func touch(_ key: Key) {
        guard newest != key, let entry = entries[key] else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next }
        else { oldest = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous }
        entries[key]?.previous = newest
        entries[key]?.next = nil
        if let newest { entries[newest]?.next = key }
        newest = key
    }
}

struct LibraryIndexEntry: Sendable {
    let identifier: String
    let creationDate: Date?
    let categories: [MediaCategory]
}

/// Built once per snapshot, off the main actor, in the library's date order.
struct LibraryScopeIndex: Sendable {
    let identifiersByScope: [LibraryScope: [String]]
    let months: [Date]
    let years: [Date]

    init(entries: [LibraryIndexEntry], calendar: Calendar = .autoupdatingCurrent) {
        var scopes: [LibraryScope: [String]] = [:]
        var months = Set<Date>()
        var years = Set<Date>()
        for entry in entries {
            if let date = entry.creationDate {
                if let month = calendar.dateInterval(of: .month, for: date)?.start {
                    scopes[.month(month), default: []].append(entry.identifier)
                    months.insert(month)
                }
                if let year = calendar.dateInterval(of: .year, for: date)?.start {
                    scopes[.year(year), default: []].append(entry.identifier)
                    years.insert(year)
                }
            }
            for category in entry.categories {
                scopes[.category(category), default: []].append(entry.identifier)
            }
        }
        identifiersByScope = scopes
        self.months = months.sorted(by: >)
        self.years = years.sorted(by: >)
    }
}
