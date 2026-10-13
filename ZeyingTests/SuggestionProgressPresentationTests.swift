import Foundation
import Testing
@testable import Zeying

struct SuggestionProgressPresentationTests {
    private func progress(_ checked: Int) -> SuggestionScanProgress {
        SuggestionScanProgress(checked: checked, total: 34_000, unavailable: 0)
    }

    @Test("大图库中不足 1% 的新结果仍在两秒后显示，过快更新会合并")
    func countsAdvanceWithoutWaitingForOnePercent() {
        let start = ContinuousClock.now
        var policy = SuggestionProgressDisplayPolicy()
        #expect(policy.update(progress(27_000), visible: true, at: start) == progress(27_000))
        #expect(policy.update(progress(27_001), visible: true, at: start.advanced(by: .seconds(1))) == nil)
        #expect(policy.update(progress(27_003), visible: true, at: start.advanced(by: .seconds(2))) == progress(27_003))
        #expect(progress(27_000).percentage(complete: false) == progress(27_003).percentage(complete: false))
    }

    @Test("隐藏页面不发布计数，返回时立即同步最新结果，原值不重复刷新")
    func hiddenStatusDoesNotPublish() {
        let start = ContinuousClock.now
        var policy = SuggestionProgressDisplayPolicy()
        #expect(policy.update(progress(10), visible: false, at: start, force: true) == nil)
        #expect(policy.update(progress(20), visible: true, at: start, force: true) == progress(20))
        #expect(policy.update(progress(25), visible: false, at: start.advanced(by: .seconds(1))) == nil)
        #expect(policy.update(progress(25), visible: true, at: start.advanced(by: .seconds(1)), force: true) == progress(25))
        #expect(policy.update(progress(25), visible: true, at: start.advanced(by: .seconds(5))) == nil)
    }

    @Test("暂停和完成时立即同步末尾计数，不丢弃最后不足两秒的结果")
    func terminalStateFlushesPendingCounts() {
        let start = ContinuousClock.now
        var policy = SuggestionProgressDisplayPolicy()
        #expect(policy.update(progress(30), visible: true, at: start) == progress(30))
        #expect(policy.update(progress(31), visible: true, at: start.advanced(by: .milliseconds(500))) == nil)
        #expect(policy.update(progress(31), visible: true, at: start.advanced(by: .milliseconds(500)), force: true) == progress(31))
    }

    @Test("页面离开后，晚到的显示请求不能重新开启实时报告")
    func staleVisibilityRequestCannotResumeUpdates() async {
        let gate = SuggestionInteractionGate()
        await gate.setProgressReportingEnabled(false, revision: 2)
        await gate.setProgressReportingEnabled(true, revision: 1)
        let hidden = await gate.progressReportingEnabled
        #expect(!hidden)
        await gate.setProgressReportingEnabled(true, revision: 3)
        let visible = await gate.progressReportingEnabled
        #expect(visible)
    }

    @Test("进度分母与实际扫描范围一致，近期及日期未知的截图不计入")
    func denominatorMatchesScanCandidates() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        func asset(_ id: String, screenshot: Bool, age: TimeInterval?) -> SuggestionAsset {
            SuggestionAsset(id: id, modifiedAt: now, createdAt: age.map { now.addingTimeInterval(-$0) },
                            width: 1200, height: 1600, isScreenshot: screenshot, isLivePhoto: false,
                            burstID: nil, isProtected: false, isEligible: true)
        }
        let assets = [
            asset("photo", screenshot: false, age: 0),
            asset("old", screenshot: true, age: 91 * 86_400),
            asset("recent", screenshot: true, age: 1 * 86_400),
            asset("boundary", screenshot: true, age: 90 * 86_400),
            asset("unknown", screenshot: true, age: nil)
        ]
        let ordered = SuggestionScanOrder.ordered(assets, now: now)
        let total = SuggestionScanOrder.candidateCount(in: assets, now: now)
        #expect(total == 2)
        #expect(total == ordered.count)
        #expect(Set(ordered.map(\.id)) == ["photo", "old"])
    }
}
