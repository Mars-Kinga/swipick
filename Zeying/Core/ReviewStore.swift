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
    @ObservationIgnored private var interactiveReviewCount = 0
    @ObservationIgnored private var hasDeferredRevision = false
    @ObservationIgnored private var pendingJournal: [String: PendingMutation] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    private(set) var revision = 0
    private(set) var errorMessage: String?
    private(set) var cleanupTotals: CleanupTotals

    private static let cleanupLedgerKey = "com.mars.zeying.cleanupLedger.v1"
    private static let reviewJournalPrefix = "com.mars.zeying.reviewJournal.v1."

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContainer = context.container
        self.defaults = defaults
        // The main context otherwise autosaves after model changes, including
        // while a review card is leaving the screen.
        self.modelContainer.mainContext.autosaveEnabled = false
        let ledger = defaults.data(forKey: Self.cleanupLedgerKey)
            .flatMap { try? JSONDecoder().decode(CleanupLedger.self, from: $0) }
        cleanupTotals = ledger?.totals ?? CleanupTotals()
        countedDeletedIdentifiers = ledger?.identifiers ?? []
        pendingJournal = Self.loadPendingJournal(from: defaults)
        reload()
        if !pendingJournal.isEmpty { scheduleFlush() }
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

    /// Chronological decision history for assets in a review group. This
    /// lets a reopened queue step back through the most recently sorted items.
    func reviewedIdentifiers(among identifiers: [String]) -> [String] {
        _ = revision
        return identifiers.enumerated()
            .filter { records[$0.element] != nil }
            .sorted { left, right in
                let leftDate = records[left.element]?.updatedAt ?? .distantPast
                let rightDate = records[right.element]?.updatedAt ?? .distantPast
                return leftDate == rightDate ? left.offset < right.offset : leftDate < rightDate
            }
            .map(\.element)
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

    /// Keep each decision in the current context and a small recovery journal.
    /// Publish one observation change and batch-save after review closes.
    func beginInteractiveReview() {
        flushTask?.cancel()
        interactiveReviewCount += 1
    }

    func endInteractiveReview() {
        guard interactiveReviewCount > 0 else { return }
        interactiveReviewCount -= 1
        if interactiveReviewCount == 0, hasDeferredRevision {
            hasDeferredRevision = false
            revision += 1
        }
        if interactiveReviewCount == 0, !pendingJournal.isEmpty {
            scheduleFlush()
        }
    }

    /// Called after the review closes or the app enters the background. The
    /// small journal keeps decisions recoverable if this batch save is delayed.
    @discardableResult
    func flushPendingReviewChanges() -> Bool {
        guard !pendingJournal.isEmpty else { return true }
        return saveOrRollback()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self,
                  self.interactiveReviewCount == 0 else { return }
            _ = self.flushPendingReviewChanges()
        }
    }

    private func publishDecisionChange() {
        if interactiveReviewCount > 0 {
            hasDeferredRevision = true
        } else {
            revision += 1
        }
    }

    @discardableResult
    func decide(_ decision: ReviewDecision, for assetIdentifier: String) -> Bool {
        let before = snapshot(for: assetIdentifier)
        let favorite = decision == .keep ? before?.pendingFavorite ?? false : false
        guard write(assetIdentifier: assetIdentifier, decision: decision, pendingFavorite: favorite) else {
            return false
        }
        history.append(UndoEntry(assetIdentifier: assetIdentifier, previous: before))
        publishDecisionChange()
        return true
    }

    /// A comparison group is one persisted transaction and one undo entry.
    /// A previous plain Keep can be changed by the group's explicit selection.
    /// Pending favorites remain protected.
    @discardableResult
    func decideGroup(_ identifiers: [String], keeping: Set<String>) -> Bool {
        decideGroup(identifiers, keeping: keeping, allowsEmptyKeep: false)
    }

    /// Explicit "keep none" action. Photos are only staged for deletion and
    /// pending favorites remain protected; the whole group is undoable.
    @discardableResult
    func stageGroupForDeletion(_ identifiers: [String]) -> Bool {
        decideGroup(identifiers, keeping: [], allowsEmptyKeep: true)
    }

    private func decideGroup(_ identifiers: [String], keeping: Set<String>, allowsEmptyKeep: Bool) -> Bool {
        let unique = Array(Set(identifiers)).sorted()
        guard !unique.isEmpty, (allowsEmptyKeep || !keeping.isEmpty), keeping.isSubset(of: Set(unique)),
              interactiveReviewCount == 0 else { return false }
        func desiredDecision(for identifier: String) -> ReviewDecision {
            keeping.contains(identifier) || records[identifier]?.pendingFavorite == true ? .keep : .delete
        }
        let changes = unique.filter { records[$0]?.decision != desiredDecision(for: $0) }
            .map { UndoChange(assetIdentifier: $0, previous: snapshot(for: $0)) }
        guard !changes.isEmpty else { return false }
        for identifier in changes.map(\.assetIdentifier) {
            let before = snapshot(for: identifier)
            let decision = desiredDecision(for: identifier)
            assign(identifier, snapshot: Snapshot(decision: decision, pendingFavorite: decision == .keep && (before?.pendingFavorite ?? false)))
        }
        guard saveOrRollback() else { return false }
        history.append(UndoEntry(changes: changes))
        publishDecisionChange()
        return true
    }

    @discardableResult
    func stageFavorite(for assetIdentifier: String, alreadyFavorite: Bool) -> Bool {
        let before = snapshot(for: assetIdentifier)
        guard write(assetIdentifier: assetIdentifier, decision: .keep, pendingFavorite: !alreadyFavorite) else {
            return false
        }
        history.append(UndoEntry(assetIdentifier: assetIdentifier, previous: before))
        publishDecisionChange()
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let entry = history.popLast() else { return false }
        let success: Bool
        if entry.changes.count > 1 {
            guard interactiveReviewCount == 0 else { history.append(entry); return false }
            for change in entry.changes { assign(change.assetIdentifier, snapshot: change.previous) }
            success = saveOrRollback()
        } else if let change = entry.changes.first, let previous = change.previous {
            success = write(
                assetIdentifier: change.assetIdentifier,
                decision: previous.decision,
                pendingFavorite: previous.pendingFavorite
            )
        } else if let change = entry.changes.first {
            success = remove(change.assetIdentifier)
        } else {
            success = false
        }
        if !success { history.append(entry) }
        publishDecisionChange()
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

    private func assign(_ identifier: String, snapshot: Snapshot?) {
        guard let snapshot else {
            if let record = records.removeValue(forKey: identifier) { context.delete(record) }
            return
        }
        let record = records[identifier] ?? ReviewRecord(assetIdentifier: identifier, decision: snapshot.decision)
        if records[identifier] == nil { context.insert(record); records[identifier] = record }
        record.decision = snapshot.decision
        record.pendingFavorite = snapshot.pendingFavorite
        record.updatedAt = .now
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
        return persistMutation(for: assetIdentifier)
    }

    private func remove(_ identifier: String) -> Bool {
        if let record = records.removeValue(forKey: identifier) {
            context.delete(record)
        }
        return persistMutation(for: identifier)
    }

    private func persistMutation(for identifier: String) -> Bool {
        guard interactiveReviewCount > 0 else { return saveOrRollback() }
        let mutation = PendingMutation(
            decision: records[identifier]?.decision,
            pendingFavorite: records[identifier]?.pendingFavorite ?? false,
            updatedAt: records[identifier]?.updatedAt ?? .now
        )
        guard let data = try? JSONEncoder().encode(mutation) else {
            context.rollback()
            reload()
            errorMessage = String(localized: "无法保存处理进度。")
            return false
        }
        pendingJournal[identifier] = mutation
        defaults.set(data, forKey: Self.reviewJournalPrefix + identifier)
        errorMessage = nil
        return true
    }

    @discardableResult
    private func saveOrRollback() -> Bool {
        do {
            try context.save()
            clearPendingJournal()
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
            for (identifier, mutation) in pendingJournal {
                if let decision = mutation.decision {
                    let record: ReviewRecord
                    if let existing = records[identifier] {
                        record = existing
                    } else {
                        record = ReviewRecord(assetIdentifier: identifier, decision: decision)
                        context.insert(record)
                        records[identifier] = record
                    }
                    record.decision = decision
                    record.pendingFavorite = mutation.pendingFavorite
                    record.updatedAt = mutation.updatedAt
                } else if let record = records.removeValue(forKey: identifier) {
                    context.delete(record)
                }
            }
            revision += 1
        } catch {
            records = [:]
            errorMessage = String(localized: "无法读取处理进度：\(error.localizedDescription)")
        }
    }

    private func clearPendingJournal() {
        guard !pendingJournal.isEmpty else { return }
        for identifier in pendingJournal.keys {
            defaults.removeObject(forKey: Self.reviewJournalPrefix + identifier)
        }
        pendingJournal.removeAll()
    }

    private static func loadPendingJournal(from defaults: UserDefaults) -> [String: PendingMutation] {
        var result: [String: PendingMutation] = [:]
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(reviewJournalPrefix) {
            guard let data = value as? Data,
                  let mutation = try? JSONDecoder().decode(PendingMutation.self, from: data)
            else { continue }
            result[String(key.dropFirst(reviewJournalPrefix.count))] = mutation
        }
        return result
    }

    private struct PendingMutation: Codable {
        let decision: ReviewDecision?
        let pendingFavorite: Bool
        let updatedAt: Date
    }

    private struct Snapshot {
        let decision: ReviewDecision
        let pendingFavorite: Bool
    }

    private struct UndoChange {
        let assetIdentifier: String
        let previous: Snapshot?
    }

    private struct UndoEntry {
        let changes: [UndoChange]
        let token = UUID()

        init(assetIdentifier: String, previous: Snapshot?) {
            changes = [UndoChange(assetIdentifier: assetIdentifier, previous: previous)]
        }

        init(changes: [UndoChange]) { self.changes = changes }
    }

    private struct CleanupLedger: Codable {
        let totals: CleanupTotals
        let identifiers: Set<String>
    }
}
