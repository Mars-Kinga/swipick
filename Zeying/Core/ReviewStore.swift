import Foundation
import Observation
import SwiftData

struct CleanupTotals: Codable, Equatable {
    var deletedPhotoCount = 0
    var deletedVideoCount = 0
    /// Sum of resource sizes known before deletion. This is not guaranteed to
    /// equal storage immediately reclaimed on the device.
    var knownDeletedBytes: Int64 = 0
}

struct DeletedAssetStat {
    let identifier: String
    let isVideo: Bool
    let knownBytes: Int64?
}

@MainActor
@Observable
final class ReviewStore {
    // A ModelContext does not keep its ModelContainer alive. Retain the
    // container for as long as decisions can be written to this context.
    @ObservationIgnored private let modelContainer: ModelContainer
    private var context: ModelContext { modelContainer.mainContext }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var records: [String: ReviewRecord] = [:]
    @ObservationIgnored private var history: [UndoEntry] = []
    @ObservationIgnored private var countedDeletedIdentifiers: Set<String> = []

    private(set) var revision = 0
    private(set) var errorMessage: String?
    private(set) var cleanupTotals: CleanupTotals

    private static let cleanupLedgerKey = "com.mars.zeying.cleanupLedger.v1"

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContainer = context.container
        self.defaults = defaults
        let ledger = defaults.data(forKey: Self.cleanupLedgerKey)
            .flatMap { try? JSONDecoder().decode(CleanupLedger.self, from: $0) }
        cleanupTotals = ledger?.totals ?? CleanupTotals()
        countedDeletedIdentifiers = ledger?.identifiers ?? []
        reload()
    }

    func decision(for assetIdentifier: String) -> ReviewDecision? {
        _ = revision
        return records[assetIdentifier]?.decision
    }

    func isPendingFavorite(_ assetIdentifier: String) -> Bool {
        _ = revision
        return records[assetIdentifier]?.pendingFavorite ?? false
    }

    func identifiers(with decision: ReviewDecision) -> [String] {
        _ = revision
        return records.values
            .filter { $0.decision == decision }
            .sorted { $0.updatedAt < $1.updatedAt }
            .map(\.assetIdentifier)
    }

    var pendingFavoriteIdentifiers: [String] {
        _ = revision
        return records.values
            .filter(\.pendingFavorite)
            .sorted { $0.updatedAt < $1.updatedAt }
            .map(\.assetIdentifier)
    }

    /// Records can become temporarily inaccessible under limited Photos access.
    /// Keep them locally so a later permission change restores the decisions.
    func unavailableIdentifiers(among accessibleIdentifiers: Set<String>) -> [String] {
        _ = revision
        return records.values
            .filter { !accessibleIdentifiers.contains($0.assetIdentifier) }
            .sorted { $0.updatedAt < $1.updatedAt }
            .map(\.assetIdentifier)
    }

    var canUndo: Bool {
        _ = revision
        return !history.isEmpty
    }

    var latestUndoToken: UUID? {
        _ = revision
        return history.last?.token
    }

    @discardableResult
    func decide(_ decision: ReviewDecision, for assetIdentifier: String) -> Bool {
        let before = snapshot(for: assetIdentifier)
        let favorite = decision == .keep ? before?.pendingFavorite ?? false : false
        guard write(assetIdentifier: assetIdentifier, decision: decision, pendingFavorite: favorite) else {
            return false
        }
        history.append(UndoEntry(assetIdentifier: assetIdentifier, previous: before))
        revision += 1
        return true
    }

    @discardableResult
    func stageFavorite(for assetIdentifier: String, alreadyFavorite: Bool) -> Bool {
        let before = snapshot(for: assetIdentifier)
        guard write(assetIdentifier: assetIdentifier, decision: .keep, pendingFavorite: !alreadyFavorite) else {
            return false
        }
        history.append(UndoEntry(assetIdentifier: assetIdentifier, previous: before))
        revision += 1
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let entry = history.popLast() else { return false }
        let success: Bool
        if let previous = entry.previous {
            success = write(
                assetIdentifier: entry.assetIdentifier,
                decision: previous.decision,
                pendingFavorite: previous.pendingFavorite
            )
        } else {
            success = remove(entry.assetIdentifier)
        }
        if !success { history.append(entry) }
        revision += 1
        return success
    }

    @discardableResult
    func undo(matching token: UUID) -> Bool {
        guard history.last?.token == token else { return false }
        return undo()
    }

    @discardableResult
    func markFavorited(_ identifiers: [String]) -> Bool {
        for identifier in identifiers {
            records[identifier]?.pendingFavorite = false
            records[identifier]?.updatedAt = .now
        }
        guard saveOrRollback() else { return false }
        clearHistory()
        revision += 1
        return true
    }

    /// Cancels staged deletions without changing the Photos library. Recovered
    /// assets remain reviewed as kept, including after the app is relaunched.
    @discardableResult
    func recoverPendingDeletions(_ identifiers: [String]) -> Bool {
        var changed = false
        for identifier in Set(identifiers) {
            guard let record = records[identifier], record.decision == .delete else { continue }
            record.decision = .keep
            record.pendingFavorite = false
            record.updatedAt = .now
            changed = true
        }
        guard changed else { return true }
        guard saveOrRollback() else { return false }
        clearHistory()
        revision += 1
        return true
    }

    @discardableResult
    func removeDeleted(_ identifiers: [String]) -> Bool {
        for identifier in identifiers {
            if let record = records.removeValue(forKey: identifier) {
                context.delete(record)
            }
        }
        guard saveOrRollback() else { return false }
        clearHistory()
        revision += 1
        return true
    }

    /// Moves the local decision to the verified still after PhotoKit has
    /// removed the original Live Photo. This is one SwiftData save so a retry
    /// after interruption cannot leave two conflicting review decisions.
    @discardableResult
    func replaceLivePhotoRecord(sourceIdentifier: String, stillIdentifier: String) -> Bool {
        let sourceRecord = records[sourceIdentifier]
        let targetRecord = records[stillIdentifier]
        if let targetRecord {
            guard let sourceRecord else { return true }
            guard targetRecord.decision == .keep,
                  targetRecord.pendingFavorite == sourceRecord.pendingFavorite else {
                errorMessage = String(localized: "静态副本已有不同的处理决定，请先核对两张照片的本地待办。")
                return false
            }
        }
        let pendingFavorite = sourceRecord?.pendingFavorite ?? false
        if let source = records.removeValue(forKey: sourceIdentifier) {
            context.delete(source)
        }
        let still: ReviewRecord
        if let targetRecord {
            still = targetRecord
        } else {
            still = ReviewRecord(assetIdentifier: stillIdentifier, decision: .keep)
            context.insert(still)
            records[stillIdentifier] = still
        }
        still.decision = .keep
        still.pendingFavorite = pendingFavorite
        still.updatedAt = .now
        guard saveOrRollback() else { return false }
        clearHistory()
        revision += 1
        return true
    }

    func clearHistory() {
        history.removeAll()
        revision += 1
    }

    func clearError() { errorMessage = nil }

    /// Called only for identifiers PhotoKit confirms as deleted. Repeating an
    /// identifier cannot inflate the cumulative count after an interrupted UI
    /// update or a retry.
    @discardableResult
    func recordCommittedDeletion(_ items: [DeletedAssetStat]) -> Bool {
        var updatedIdentifiers = countedDeletedIdentifiers
        var updatedTotals = cleanupTotals
        for item in items where updatedIdentifiers.insert(item.identifier).inserted {
            if item.isVideo {
                updatedTotals.deletedVideoCount += 1
            } else {
                updatedTotals.deletedPhotoCount += 1
            }
            if let bytes = item.knownBytes, bytes > 0 {
                updatedTotals.knownDeletedBytes += bytes
            }
        }
        let ledger = CleanupLedger(totals: updatedTotals, identifiers: updatedIdentifiers)
        guard let data = try? JSONEncoder().encode(ledger) else {
            errorMessage = String(localized: "无法保存清理统计。")
            return false
        }
        defaults.set(data, forKey: Self.cleanupLedgerKey)
        countedDeletedIdentifiers = updatedIdentifiers
        cleanupTotals = updatedTotals
        return true
    }

    private func snapshot(for identifier: String) -> Snapshot? {
        guard let record = records[identifier] else { return nil }
        return Snapshot(decision: record.decision, pendingFavorite: record.pendingFavorite)
    }

    private func write(assetIdentifier: String, decision: ReviewDecision, pendingFavorite: Bool) -> Bool {
        let record: ReviewRecord
        if let existing = records[assetIdentifier] {
            record = existing
        } else {
            record = ReviewRecord(assetIdentifier: assetIdentifier, decision: decision)
            context.insert(record)
            records[assetIdentifier] = record
        }
        record.decision = decision
        record.pendingFavorite = pendingFavorite
        record.updatedAt = .now
        return saveOrRollback()
    }

    private func remove(_ identifier: String) -> Bool {
        if let record = records.removeValue(forKey: identifier) {
            context.delete(record)
        }
        return saveOrRollback()
    }

    @discardableResult
    private func saveOrRollback() -> Bool {
        do {
            try context.save()
            errorMessage = nil
            return true
        } catch {
            context.rollback()
            reload()
            errorMessage = String(localized: "无法保存处理进度：\(error.localizedDescription)")
            return false
        }
    }

    private func reload() {
        do {
            records = Dictionary(
                uniqueKeysWithValues: try context.fetch(FetchDescriptor<ReviewRecord>())
                    .map { ($0.assetIdentifier, $0) }
            )
            revision += 1
        } catch {
            records = [:]
            errorMessage = String(localized: "无法读取处理进度：\(error.localizedDescription)")
        }
    }

    private struct Snapshot {
        let decision: ReviewDecision
        let pendingFavorite: Bool
    }

    private struct UndoEntry {
        let assetIdentifier: String
        let previous: Snapshot?
        let token = UUID()
    }

    private struct CleanupLedger: Codable {
        let totals: CleanupTotals
        let identifiers: Set<String>
    }
}
