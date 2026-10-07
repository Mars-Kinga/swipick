import Foundation
import SwiftData
import Testing
@testable import Zeying

@MainActor
struct SuggestionFlowAcceptanceTests {
    @Test("一张也不想要只将本组加入待删，保留已保护照片并可整组撤销")
    func stageEntireGroupForDeletionAndUndo() throws {
        let container = try ModelContainer(for: ReviewRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ReviewStore(context: container.mainContext)
        #expect(store.decide(.keep, for: "protected"))
        #expect(store.stageGroupForDeletion(["a", "b", "protected"]))
        let token = try #require(store.latestUndoToken)
        #expect(store.decision(for: "a") == .delete)
        #expect(store.decision(for: "b") == .delete)
        #expect(store.decision(for: "protected") == .keep)
        #expect(store.undo(matching: token))
        #expect(store.decision(for: "a") == nil)
        #expect(store.decision(for: "b") == nil)
        #expect(store.decision(for: "protected") == .keep)
    }

    @Test("两组决定的 token 只能撤销对应最新组，撤销结果重新读取仍正确")
    func consecutiveGroupsUndoWithoutCrossingGroups() throws {
        let container = try ModelContainer(for: ReviewRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ReviewStore(context: container.mainContext)
        #expect(store.decideGroup(["a", "b"], keeping: ["a"]))
        let first = try #require(store.latestUndoToken)
        #expect(store.decideGroup(["c", "d"], keeping: ["c", "d"]))
        let second = try #require(store.latestUndoToken)
        #expect(!store.undo(matching: first))
        #expect(store.decision(for: "d") == .keep)
        #expect(store.undo(matching: second))
        #expect(store.decision(for: "c") == nil)
        #expect(store.decision(for: "d") == nil)
        #expect(store.decision(for: "b") == .delete)
        #expect(store.undo(matching: first))
        let reopened = ReviewStore(context: container.mainContext)
        for id in ["a", "b", "c", "d"] { #expect(reopened.decision(for: id) == nil) }
    }

    @Test("全保留和单张保留可恢复原先稍后与待删决定，不改收藏和相簿待办")
    func undoRestoresPriorRecordsAndPreservesProtectedTasks() throws {
        let container = try ModelContainer(for: ReviewRecord.self, PendingAlbumAssignment.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ReviewStore(context: container.mainContext)
        let assignments = PendingAlbumAssignmentStore(context: container.mainContext)
        #expect(store.decide(.later, for: "later"))
        #expect(store.decide(.delete, for: "deleted"))
        #expect(store.stageFavorite(for: "favorite", alreadyFavorite: false))
        #expect(assignments.assign(assetIdentifier: "album", albumIdentifier: "target", albumTitle: "Trips"))
        let ids = ["later", "deleted", "favorite", "album", "new"]
        #expect(store.decideGroup(ids, keeping: Set(ids)))
        #expect(store.undo())
        #expect(store.decision(for: "later") == .later)
        #expect(store.decision(for: "deleted") == .delete)
        #expect(store.decision(for: "new") == nil)
        #expect(store.isPendingFavorite("favorite"))
        // Comparison passes album protection in its keep set; ReviewStore owns only review records.
        #expect(store.decideGroup(["favorite", "album", "new"], keeping: ["album"]))
        #expect(store.decision(for: "favorite") == .keep)
        #expect(store.decision(for: "new") == .delete)
        #expect(store.undo())
        let reopened = ReviewStore(context: container.mainContext)
        let reopenedAssignments = PendingAlbumAssignmentStore(context: container.mainContext)
        #expect(reopened.isPendingFavorite("favorite"))
        #expect(reopened.decision(for: "album") == nil)
        #expect(reopenedAssignments.assignment(for: "album")?.albumIdentifier == "target")
    }

    @Test("外部决定插入后过期的整组撤销 token 不会覆盖新决定")
    func staleTokenDoesNotLoseExternalDecision() throws {
        let container = try ModelContainer(for: ReviewRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ReviewStore(context: container.mainContext)
        #expect(store.decideGroup(["a", "b"], keeping: ["a"]))
        let groupToken = try #require(store.latestUndoToken)
        #expect(store.decide(.later, for: "b"))
        #expect(!store.undo(matching: groupToken))
        #expect(store.decision(for: "b") == .later)
        #expect(store.undo())
        #expect(store.decision(for: "b") == .delete)
        #expect(store.undo(matching: groupToken))
        #expect(store.decision(for: "b") == nil)
    }

    @Test("截图前后组的会话位置和跳过分别持久化，回退不会恢复错误组")
    func sessionPositionAndSkipRemainIndependent() throws {
        let suite = "suggestion-flow-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(for: ReviewRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ReviewStore(context: container.mainContext, defaults: defaults)
        let service = PhotoSuggestionService(defaults: defaults)
        let groups = [group("before", kind: .similar), group("screens", kind: .screenshots), group("after", kind: .similar)]
        service.skip(groups[0])
        service.rememberSession(groups, index: 1)
        #expect(PhotoSuggestionService(defaults: defaults).resumeGroupIDs == ["screens", "after"])
        service.rememberSession(groups, index: 2)
        #expect(PhotoSuggestionService(defaults: defaults).resumeGroupIDs == ["after"])
        service.rememberSession(groups, index: 1)
        service.restoreSkipped()
        let reopened = PhotoSuggestionService(defaults: defaults)
        #expect(reopened.resumeGroupIDs == ["screens", "after"])
        #expect(reopened.skippedIDs.isEmpty)
        #expect(store.reviewedIdentifiers(among: groups.flatMap(\.assetIDs)).isEmpty)
        service.rememberSession(groups, index: groups.count)
        #expect(PhotoSuggestionService(defaults: defaults).resumeGroupIDs.isEmpty)
    }

    private func group(_ id: String, kind: SuggestionKind) -> CleanupSuggestion {
        CleanupSuggestion(id: id, kind: kind, reason: .possibleVersions, assetIDs: ["\(id)-a", "\(id)-b"], recommendedKeepID: nil, protectedIDs: [], knownBytes: nil, newestDate: nil)
    }
}
