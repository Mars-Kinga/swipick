import Foundation
import SwiftData
import Testing
@testable import Zeying

@MainActor
struct ReviewStoreTests {
    @Test("重新进入分类时可按实际处理顺序回看已整理照片")
    func reviewedHistoryUsesDecisionOrder() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let older = ReviewRecord(assetIdentifier: "history-older", decision: .keep)
        older.updatedAt = Date(timeIntervalSince1970: 100)
        let newer = ReviewRecord(assetIdentifier: "history-newer", decision: .delete)
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        container.mainContext.insert(older)
        container.mainContext.insert(newer)
        try container.mainContext.save()

        let store = ReviewStore(context: container.mainContext)
        #expect(store.reviewedIdentifiers(among: ["history-newer", "history-unreviewed", "history-older"])
            == ["history-older", "history-newer"])
    }

    @Test("加入相簿待办模型后仍可读取旧审核记录")
    func expandedSchemaKeepsExistingReviewRecords() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appending(path: "ZeyingSchemaMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let storeURL = folderURL.appending(path: "Model.store")
        do {
            let legacySchema = Schema([ReviewRecord.self])
            let configuration = ModelConfiguration(
                "ZeyingLegacy",
                schema: legacySchema,
                url: storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: legacySchema, configurations: configuration)
            let record = ReviewRecord(assetIdentifier: "legacy-photo", decision: .keep)
            container.mainContext.insert(record)
            try container.mainContext.save()
        }

        let expandedSchema = Schema([ReviewRecord.self, PendingAlbumAssignment.self])
        let expandedConfiguration = ModelConfiguration(
            "ZeyingExpanded",
            schema: expandedSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let expandedContainer = try ModelContainer(
            for: expandedSchema,
            configurations: expandedConfiguration
        )
        let records = try expandedContainer.mainContext.fetch(FetchDescriptor<ReviewRecord>())
        let assignments = try expandedContainer.mainContext.fetch(FetchDescriptor<PendingAlbumAssignment>())
        #expect(records.count == 1)
        #expect(records.first?.assetIdentifier == "legacy-photo")
        #expect(assignments.isEmpty)
    }

    @Test("相簿待办可更新目标并转移到静态副本")
    func albumAssignmentsUpdateAndReplaceAsset() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self, PendingAlbumAssignment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = PendingAlbumAssignmentStore(context: container.mainContext)

        #expect(store.assign(
            assetIdentifier: "live-photo",
            albumIdentifier: "album-id",
            albumTitle: "旅行"
        ))
        #expect(store.assign(
            assetIdentifier: "live-photo",
            albumIdentifier: "album-id-2",
            albumTitle: "家人"
        ))
        #expect(store.count == 1)
        #expect(store.assignment(for: "live-photo")?.albumTitle == "家人")

        #expect(store.replaceAssetIdentifier(
            sourceIdentifier: "live-photo",
            stillIdentifier: "static-copy"
        ))
        #expect(store.assignment(for: "live-photo") == nil)
        #expect(store.assignment(for: "static-copy")?.albumTitle == "家人")

        let reopened = PendingAlbumAssignmentStore(context: container.mainContext)
        #expect(reopened.assignment(for: "static-copy")?.albumIdentifier == "album-id-2")
    }

    @Test("新相簿创建后记录标识供失败重试使用")
    func createdAlbumIdentifierSurvivesRetry() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self, PendingAlbumAssignment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = PendingAlbumAssignmentStore(context: container.mainContext)
        #expect(store.assign(assetIdentifier: "photo-a", albumIdentifier: nil, albumTitle: "旅行"))
        #expect(store.assign(assetIdentifier: "photo-b", albumIdentifier: nil, albumTitle: "旅行"))
        #expect(store.stageAlbumCreation(
            title: "旅行",
            for: ["photo-a", "photo-b"],
            existingAlbumIdentifiers: ["old-album"]
        ))
        let staged = PendingAlbumAssignmentStore(context: container.mainContext)
        #expect(staged.assignment(for: "photo-a")?.albumCreationBaselineIdentifiers == ["old-album"])
        #expect(store.resolveNewAlbum(
            identifier: "created-album",
            title: "旅行",
            for: ["photo-a", "photo-b"]
        ))

        let reopened = PendingAlbumAssignmentStore(context: container.mainContext)
        #expect(reopened.assignment(for: "photo-a")?.albumIdentifier == "created-album")
        #expect(reopened.assignment(for: "photo-b")?.albumIdentifier == "created-album")
        #expect(!reopened.resolveNewAlbum(
            identifier: "second-album",
            title: "旅行",
            for: ["photo-a", "photo-b"]
        ))
    }

    @Test("静态副本已有不同相簿目标时保留两边待办")
    func conflictingAlbumTargetsRemainVisible() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self, PendingAlbumAssignment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = PendingAlbumAssignmentStore(context: container.mainContext)
        #expect(store.assign(assetIdentifier: "live", albumIdentifier: "album-a", albumTitle: "A"))
        #expect(store.assign(assetIdentifier: "still", albumIdentifier: "album-b", albumTitle: "B"))
        #expect(!store.replaceAssetIdentifier(sourceIdentifier: "live", stillIdentifier: "still"))
        #expect(store.assignment(for: "live")?.albumIdentifier == "album-a")
        #expect(store.assignment(for: "still")?.albumIdentifier == "album-b")
    }

    @Test("容器退出创建函数后，首次决定仍可保存")
    func containerOutlivesItsCreationScope() throws {
        func makeStore() throws -> ReviewStore {
            let container = try ModelContainer(
                for: ReviewRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            return ReviewStore(context: container.mainContext)
        }

        let store = try makeStore()
        #expect(store.decide(.keep, for: "photo-after-container-scope"))
        #expect(store.decision(for: "photo-after-container-scope") == .keep)
    }

    @Test("决定会保存，并可连续撤销")
    func decisionsPersistAndUndo() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ReviewStore(context: container.mainContext)

        #expect(store.decide(.delete, for: "photo-A"))
        #expect(store.decide(.later, for: "photo-B"))
        #expect(store.identifiers(with: .delete) == ["photo-A"])
        #expect(store.identifiers(with: .later) == ["photo-B"])

        #expect(store.undo())
        #expect(store.decision(for: "photo-B") == nil)
        #expect(store.undo())
        #expect(store.decision(for: "photo-A") == nil)

        #expect(store.decide(.keep, for: "photo-A"))
        let reopened = ReviewStore(context: container.mainContext)
        #expect(reopened.decision(for: "photo-A") == .keep)
    }

    @Test("连续审核保留即时决定，退出后再通知主页刷新")
    func interactiveReviewDefersOnlyObservation() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suite = "com.mars.zeying.tests.interactiveReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReviewStore(context: container.mainContext, defaults: defaults)
        let initialRevision = store.revision

        store.beginInteractiveReview()
        #expect(store.decide(.delete, for: "photo-A"))
        #expect(store.decide(.keep, for: "photo-B"))
        #expect(store.revision == initialRevision)
        #expect(store.decision(for: "photo-A") == .delete)
        #expect(store.decision(for: "photo-B") == .keep)

        store.endInteractiveReview()
        #expect(store.revision == initialRevision + 1)
        #expect(store.flushPendingReviewChanges())
    }

    @Test("连续审核未批量写入时，重启可从待写记录恢复决定与撤销")
    func pendingReviewJournalRecoversBeforeBatchSave() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ZeyingReviewJournal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "com.mars.zeying.tests.reviewJournal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let schema = Schema([ReviewRecord.self])
        let configuration = ModelConfiguration(
            "ReviewJournalTest",
            schema: schema,
            url: folder.appending(path: "Model.store"),
            cloudKitDatabase: .none
        )

        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            let store = ReviewStore(context: container.mainContext, defaults: defaults)
            store.beginInteractiveReview()
            #expect(store.decide(.keep, for: "photo-A"))
            #expect(store.decide(.delete, for: "photo-B"))
            #expect(store.undo())
            #expect(store.decision(for: "photo-B") == nil)
            // Simulate a process ending before the scheduled SwiftData batch.
        }

        let reopenedContainer = try ModelContainer(for: schema, configurations: configuration)
        let persistedBeforeReplay = try ModelContext(reopenedContainer).fetch(FetchDescriptor<ReviewRecord>())
        #expect(persistedBeforeReplay.isEmpty)
        let reopened = ReviewStore(context: reopenedContainer.mainContext, defaults: defaults)
        reopened.beginInteractiveReview()
        #expect(reopened.decision(for: "photo-A") == .keep)
        #expect(reopened.decision(for: "photo-B") == nil)
        reopened.endInteractiveReview()
        #expect(reopened.flushPendingReviewChanges())

        let persistedAfterFlush = try ModelContext(reopenedContainer).fetch(FetchDescriptor<ReviewRecord>())
        #expect(persistedAfterFlush.map(\.assetIdentifier) == ["photo-A"])
    }

    @Test("收藏即保留；改为待删时清除待收藏")
    func favoriteAndDeleteAreExclusive() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ReviewStore(context: container.mainContext)

        #expect(store.stageFavorite(for: "photo-A", alreadyFavorite: false))
        #expect(store.decision(for: "photo-A") == .keep)
        #expect(store.isPendingFavorite("photo-A"))

        #expect(store.decide(.delete, for: "photo-A"))
        #expect(store.decision(for: "photo-A") == .delete)
        #expect(!store.isPendingFavorite("photo-A"))

        #expect(store.undo())
        #expect(store.decision(for: "photo-A") == .keep)
        #expect(store.isPendingFavorite("photo-A"))
    }

    @Test("系统提交成功后只清理对应待办")
    func committedItemsLeavePendingQueue() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ReviewStore(context: container.mainContext)

        #expect(store.stageFavorite(for: "photo-A", alreadyFavorite: false))
        #expect(store.decide(.delete, for: "photo-B"))
        #expect(store.markFavorited(["photo-A"]))
        #expect(store.pendingFavoriteIdentifiers.isEmpty)
        #expect(store.decision(for: "photo-A") == .keep)
        #expect(store.identifiers(with: .delete) == ["photo-B"])

        #expect(store.removeDeleted(["photo-B"]))
        #expect(store.decision(for: "photo-B") == nil)
    }

    @Test("待删照片可单张或批量恢复为保留，重启后仍生效")
    func pendingDeletionsCanBeRecovered() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ReviewStore(context: container.mainContext)

        #expect(store.decide(.delete, for: "photo-A"))
        #expect(store.decide(.delete, for: "photo-B"))
        #expect(store.decide(.keep, for: "photo-C"))
        #expect(store.recoverPendingDeletions(["photo-A"]))
        #expect(store.identifiers(with: .delete) == ["photo-B"])
        #expect(store.decision(for: "photo-A") == .keep)

        #expect(store.recoverPendingDeletions(["photo-B", "photo-C"]))
        #expect(store.identifiers(with: .delete).isEmpty)
        let reopened = ReviewStore(context: container.mainContext)
        #expect(reopened.decision(for: "photo-A") == .keep)
        #expect(reopened.decision(for: "photo-B") == .keep)
        #expect(reopened.decision(for: "photo-C") == .keep)
    }

    @Test("只撤销当前审核操作，避免其他入口的编辑串位")
    func undoMatchesItsAction() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ReviewStore(context: container.mainContext)

        #expect(store.decide(.delete, for: "photo-A"))
        let firstToken = try #require(store.latestUndoToken)
        #expect(store.decide(.keep, for: "photo-B"))
        let secondToken = try #require(store.latestUndoToken)

        #expect(!store.undo(matching: firstToken))
        #expect(store.decision(for: "photo-B") == .keep)
        #expect(store.undo(matching: secondToken))
        #expect(store.undo(matching: firstToken))
        #expect(store.decision(for: "photo-A") == nil)
    }

    @Test("删除统计跨次保留且同一资源不会重复计数")
    func cleanupTotalsPersistWithoutDoubleCounting() throws {
        let suiteName = "ZeyingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ReviewStore(context: container.mainContext, defaults: defaults)

        store.recordCommittedDeletion([
            DeletedAssetStat(identifier: "photo-A", isVideo: false, knownBytes: 2_000_000),
            DeletedAssetStat(identifier: "video-B", isVideo: true, knownBytes: nil)
        ])
        store.recordCommittedDeletion([
            DeletedAssetStat(identifier: "photo-A", isVideo: false, knownBytes: 2_000_000)
        ])

        let reopened = ReviewStore(context: container.mainContext, defaults: defaults)
        #expect(reopened.cleanupTotals.deletedPhotoCount == 1)
        #expect(reopened.cleanupTotals.deletedVideoCount == 1)
        #expect(reopened.cleanupTotals.knownDeletedBytes == 2_000_000)
    }

    @Test("实况照片转静态后决定与待收藏转移到新照片")
    func liveReplacementPreservesPendingDecision() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ReviewStore(context: container.mainContext)

        #expect(store.stageFavorite(for: "live-original", alreadyFavorite: false))
        #expect(store.replaceLivePhotoRecord(
            sourceIdentifier: "live-original",
            stillIdentifier: "static-copy"
        ))
        #expect(store.decision(for: "live-original") == nil)
        #expect(store.decision(for: "static-copy") == .keep)
        #expect(store.isPendingFavorite("static-copy"))

        // Reconciliation after an interrupted update must not duplicate work.
        #expect(store.replaceLivePhotoRecord(
            sourceIdentifier: "live-original",
            stillIdentifier: "static-copy"
        ))
        let reopened = ReviewStore(context: container.mainContext)
        #expect(reopened.decision(for: "static-copy") == .keep)
        #expect(reopened.isPendingFavorite("static-copy"))
    }

    @Test("静态副本已有待删决定时转换不会覆盖")
    func conflictingStillDecisionRemainsVisible() throws {
        let container = try ModelContainer(
            for: ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ReviewStore(context: container.mainContext)
        #expect(store.decide(.keep, for: "live"))
        #expect(store.decide(.delete, for: "still"))
        #expect(!store.replaceLivePhotoRecord(sourceIdentifier: "live", stillIdentifier: "still"))
        #expect(store.decision(for: "live") == .keep)
        #expect(store.decision(for: "still") == .delete)
    }

    @Test("损坏的静态转换记录会显示错误而不被覆盖")
    func unreadableConversionJournalIsRetained() throws {
        let suite = "ZeyingConversionJournalTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid-journal".utf8)
        defaults.set(original, forKey: "com.mars.zeying.liveConversionJournal.v1")

        let manager = LivePhotoConversionManager(defaults: defaults)
        #expect(manager.journalError != nil)
        #expect(defaults.data(forKey: "com.mars.zeying.liveConversionJournal.v1") == original)
    }
}
