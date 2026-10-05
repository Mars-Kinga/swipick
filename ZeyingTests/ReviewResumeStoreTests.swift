import Foundation
import Testing
@testable import Zeying

@MainActor
struct ReviewResumeStoreTests {
    @Test("上次处理的月份会在重新打开后恢复")
    func lastMonthPersists() throws {
        let suiteName = "ZeyingTests.ReviewResume.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 19)))
        let first = ReviewResumeStore(defaults: defaults)
        first.rememberMonth(containing: date)

        let reopened = ReviewResumeStore(defaults: defaults)
        let remembered = try #require(reopened.lastMonth)
        #expect(Calendar.current.isDate(remembered, equalTo: date, toGranularity: .month))

        reopened.rememberMonth(containing: nil)
        #expect(reopened.lastMonth == remembered)
    }

    @Test("继续清理会记住类别和相簿入口")
    func reviewScopePersists() throws {
        let suiteName = "ZeyingTests.ReviewScope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2)))
        let first = ReviewResumeStore(defaults: defaults)
        first.remember(scope: .category(.screenshot), containing: date)

        let reopened = ReviewResumeStore(defaults: defaults)
        #expect(reopened.lastScope == .category(.screenshot))
        #expect(Calendar.current.isDate(try #require(reopened.lastMonth), equalTo: date, toGranularity: .month))

        reopened.remember(scope: .album("album-123"), containing: nil)
        reopened.remember(scope: .later, containing: nil)
        #expect(ReviewResumeStore(defaults: defaults).lastScope == .album("album-123"))
    }
}
