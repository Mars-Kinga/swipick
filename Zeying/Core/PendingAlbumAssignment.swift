import Foundation
import Observation
import SwiftData

/// A local, reversible instruction to add an asset to a user album.
///
/// Existing-album choices are staged until the final checklist. New albums
/// created from the review screen are written directly through PhotoKit and
/// do not use this model. Older staged new-album records remain supported.
@Model
final class PendingAlbumAssignment {
    @Attribute(.unique) var assetIdentifier: String
    var albumIdentifier: String?
    var albumTitle: String
    var albumCreationBaselineIdentifiers: [String]?
    var updatedAt: Date

    init(
        assetIdentifier: String,
        albumIdentifier: String?,
        albumTitle: String,
        updatedAt: Date = .now
    ) {
        self.assetIdentifier = assetIdentifier
        self.albumIdentifier = albumIdentifier
        self.albumTitle = albumTitle
        self.albumCreationBaselineIdentifiers = nil
        self.updatedAt = updatedAt
    }

    var isNewAlbum: Bool { albumIdentifier == nil }
}

/// Persists album choices locally and exposes them as observable state for the
/// review and checklist screens.
@MainActor
@Observable
final class PendingAlbumAssignmentStore {
    // ModelContext does not retain its container. Keep it alive for the
    // lifetime of this store so writes remain valid after app launch.
    @ObservationIgnored private let modelContainer: ModelContainer
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var assignmentsByAsset: [String: PendingAlbumAssignment] = [:]

    private(set) var revision = 0
    private(set) var errorMessage: String?

    init(context: ModelContext) {
        modelContainer = context.container
        self.context = context
        reload()
    }

    var assignments: [PendingAlbumAssignment] {
        _ = revision
        return assignmentsByAsset.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    var count: Int {
        _ = revision
        return assignmentsByAsset.count
    }

    func assignment(for assetIdentifier: String) -> PendingAlbumAssignment? {
        _ = revision
        return assignmentsByAsset[assetIdentifier]
    }

    func assignments(for albumIdentifier: String) -> [PendingAlbumAssignment] {
        _ = revision
        return assignments.filter { $0.albumIdentifier == albumIdentifier }
    }

    /// Stages one target album per asset. Re-selecting an album replaces the
    /// previous local target, which keeps repeated entry points consistent.
    @discardableResult
    func assign(
        assetIdentifier: String,
        albumIdentifier: String?,
        albumTitle: String
    ) -> Bool {
        let title = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetIdentifier.isEmpty, !title.isEmpty else {
            errorMessage = String(localized: "相簿名称不能为空。")
            return false
        }

        let record: PendingAlbumAssignment
        if let existing = assignmentsByAsset[assetIdentifier] {
            record = existing
            record.albumIdentifier = albumIdentifier
            record.albumTitle = title
            record.albumCreationBaselineIdentifiers = nil
            record.updatedAt = .now
        } else {
            record = PendingAlbumAssignment(
                assetIdentifier: assetIdentifier,
                albumIdentifier: albumIdentifier,
                albumTitle: title
            )
            context.insert(record)
            assignmentsByAsset[assetIdentifier] = record
        }

        guard saveOrRollback() else { return false }
        revision += 1
        return true
    }

    @discardableResult
    func remove(assetIdentifier: String) -> Bool {
        guard let record = assignmentsByAsset.removeValue(forKey: assetIdentifier) else {
            return true
        }
        context.delete(record)
        guard saveOrRollback() else {
            reload()
            return false
        }
        revision += 1
        return true
    }

    /// Removes only assignments that PhotoKit confirms as applied.
    @discardableResult
    func removeApplied(_ assetIdentifiers: [String]) -> Bool {
        var removed = false
        for identifier in assetIdentifiers {
            if let record = assignmentsByAsset.removeValue(forKey: identifier) {
                context.delete(record)
                removed = true
            }
        }
        guard removed else { return true }
        guard saveOrRollback() else {
            reload()
            return false
        }
        revision += 1
        return true
    }

    /// Transfers a pending album target to a newly-created replacement asset.
    /// Conversion can be retried safely: if the replacement already has the
    /// assignment, the stale source record is simply removed.
    @discardableResult
    func replaceAssetIdentifier(sourceIdentifier: String, stillIdentifier: String) -> Bool {
        guard !sourceIdentifier.isEmpty, !stillIdentifier.isEmpty else { return false }
        guard sourceIdentifier != stillIdentifier,
              let source = assignmentsByAsset[sourceIdentifier] else {
            return true
        }

        if let existing = assignmentsByAsset[stillIdentifier] {
            guard existing.albumIdentifier == source.albumIdentifier,
                  existing.albumTitle == source.albumTitle,
                  existing.albumCreationBaselineIdentifiers == source.albumCreationBaselineIdentifiers else {
                errorMessage = String(localized: "静态副本已有不同的相簿目标，请先核对两张照片的相簿待办。")
                return false
            }
            context.delete(source)
            assignmentsByAsset.removeValue(forKey: sourceIdentifier)
        } else {
            source.assetIdentifier = stillIdentifier
            source.updatedAt = .now
            assignmentsByAsset.removeValue(forKey: sourceIdentifier)
            assignmentsByAsset[stillIdentifier] = source
        }

        guard saveOrRollback() else { return false }
        revision += 1
        return true
    }

    /// Saves the newly created PhotoKit album before any asset is added to it.
    /// A retry then reuses that album instead of creating another one.
    @discardableResult
    func resolveNewAlbum(
        identifier: String,
        title: String,
        for assetIdentifiers: [String]
    ) -> Bool {
        guard !identifier.isEmpty, !assetIdentifiers.isEmpty,
              assetIdentifiers.allSatisfy({ assetIdentifier in
                  guard let assignment = assignmentsByAsset[assetIdentifier] else { return false }
                  return assignment.isNewAlbum && assignment.albumTitle == title
              }) else {
            errorMessage = String(localized: "相簿整理待办已变更，请重新确认。")
            return false
        }
        for assetIdentifier in assetIdentifiers {
            assignmentsByAsset[assetIdentifier]?.albumIdentifier = identifier
            assignmentsByAsset[assetIdentifier]?.albumCreationBaselineIdentifiers = nil
            assignmentsByAsset[assetIdentifier]?.updatedAt = .now
        }
        guard saveOrRollback() else { return false }
        revision += 1
        return true
    }

    /// Records which same-named albums existed before PhotoKit creates one.
    /// If the app stops before receiving the new identifier, a later retry
    /// can detect the extra album and ask the user to select it explicitly.
    @discardableResult
    func stageAlbumCreation(
        title: String,
        for assetIdentifiers: [String],
        existingAlbumIdentifiers: [String]
    ) -> Bool {
        guard !assetIdentifiers.isEmpty,
              assetIdentifiers.allSatisfy({ assetIdentifier in
                  guard let assignment = assignmentsByAsset[assetIdentifier] else { return false }
                  return assignment.isNewAlbum && assignment.albumTitle == title
              }) else {
            errorMessage = String(localized: "相簿整理待办已变更，请重新确认。")
            return false
        }
        for assetIdentifier in assetIdentifiers {
            assignmentsByAsset[assetIdentifier]?.albumCreationBaselineIdentifiers =
                existingAlbumIdentifiers
        }
        guard saveOrRollback() else { return false }
        revision += 1
        return true
    }

    func clearError() { errorMessage = nil }

    private func saveOrRollback() -> Bool {
        do {
            try context.save()
            errorMessage = nil
            return true
        } catch {
            context.rollback()
            reload()
            errorMessage = String(localized: "无法保存相簿整理进度：\(error.localizedDescription)")
            return false
        }
    }

    private func reload() {
        do {
            assignmentsByAsset = Dictionary(
                uniqueKeysWithValues: try context.fetch(FetchDescriptor<PendingAlbumAssignment>())
                    .map { ($0.assetIdentifier, $0) }
            )
            revision += 1
        } catch {
            assignmentsByAsset = [:]
            errorMessage = String(localized: "无法读取相簿整理进度：\(error.localizedDescription)")
        }
    }
}
