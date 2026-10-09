import Foundation
import Testing
@testable import Zeying

@MainActor
struct AlbumSelectionHistoryTests {
    @Test("连续选择六次 kpop，立即排在使用三次及未使用的相簿之前")
    func frequentChoicesRankBeforeAlphabeticalOrder() {
        let (history, defaults, suite) = history()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<3 { history.recordSelection(of: "family") }
        for _ in 0..<6 { history.recordSelection(of: "kpop") }

        #expect(history.ordered(albums).map(\.id) == ["kpop", "family", "a"])
        #expect(defaults.dictionary(forKey: "com.mars.zeying.albumSelectionCounts.v1")?["kpop"] as? Int == 6)
    }

    @Test("常用排序在重新启动后保留，并兼容已有使用记录")
    func historySurvivesReload() {
        let (_, defaults, suite) = history()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["family": 3], forKey: "com.mars.zeying.albumSelectionCounts.v1")
        let history = AlbumSelectionHistory(defaults: defaults)
        for _ in 0..<6 { history.recordSelection(of: "kpop") }

        let reloaded = AlbumSelectionHistory(defaults: defaults)
        #expect(reloaded.ordered(albums).map(\.id) == ["kpop", "family", "a"])
    }

    @Test("旧版尚未写入照片的六次相簿选择也进入常用排序")
    func importsOldPendingChoicesOnce() {
        let (history, defaults, suite) = history()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = Array(repeating: "kpop", count: 6)
        history.importPendingSelectionsIfNeeded(pending)
        #expect(history.ordered(albums).first?.id == "kpop")

        // Reopening the app while these same assignments remain pending must
        // not count them again, nor repeat the one-time migration.
        let reloaded = AlbumSelectionHistory(defaults: defaults)
        reloaded.importPendingSelectionsIfNeeded(pending + ["family"])
        #expect(defaults.dictionary(forKey: "com.mars.zeying.albumSelectionCounts.v1") as? [String: Int] == ["kpop": 6])
        reloaded.recordSelection(of: "kpop")
        #expect(defaults.dictionary(forKey: "com.mars.zeying.albumSelectionCounts.v1")?["kpop"] as? Int == 7)
    }

    @Test("补入旧待办不会重复增加已有较高次数")
    func pendingImportPreservesExistingHistory() {
        let (_, defaults, suite) = history()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["family": 9, "kpop": 2], forKey: "com.mars.zeying.albumSelectionCounts.v1")
        let history = AlbumSelectionHistory(defaults: defaults)
        history.importPendingSelectionsIfNeeded(["family", "family"] + Array(repeating: "kpop", count: 6))

        #expect(defaults.dictionary(forKey: "com.mars.zeying.albumSelectionCounts.v1") as? [String: Int] == ["family": 9, "kpop": 6])
        #expect(history.ordered(albums).map(\.id) == ["family", "kpop", "a"])
    }

    @Test("同频率按名称和标识稳定排序，新建相簿仍优先可见")
    func tiesAndNewAlbumsHaveStableOrder() {
        let (history, defaults, suite) = history()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sameTitles = [
            PhotoAlbumOption(id: "b", title: "Album", count: nil),
            PhotoAlbumOption(id: "a", title: "Album", count: nil),
            PhotoAlbumOption(id: "z", title: "Zoo", count: nil)
        ]
        #expect(history.ordered(sameTitles).map(\.id) == ["a", "b", "z"])
        #expect(history.ordered(sameTitles, newlyCreatedIdentifier: "z").map(\.id) == ["z", "a", "b"])
    }

    private var albums: [PhotoAlbumOption] {
        [
            PhotoAlbumOption(id: "a", title: "A", count: nil),
            PhotoAlbumOption(id: "family", title: "Family", count: 12),
            PhotoAlbumOption(id: "kpop", title: "kpop", count: 20)
        ]
    }

    private func history() -> (AlbumSelectionHistory, UserDefaults, String) {
        let suite = "AlbumSelectionHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AlbumSelectionHistory(defaults: defaults), defaults, suite)
    }
}
