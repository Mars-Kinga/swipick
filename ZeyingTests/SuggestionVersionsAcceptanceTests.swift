import Foundation
import Testing
@testable import Zeying

struct SuggestionVersionsAcceptanceTests {
    private let date = Date(timeIntervalSince1970: 1_780_000_000)

    private func asset(_ id: String, days: Int = 0, live: Bool = false, protected: Bool = false) -> SuggestionAsset {
        SuggestionAsset(id: id, modifiedAt: date, createdAt: date.addingTimeInterval(Double(days) * 86_400),
                        width: 1200, height: 1600, isScreenshot: false, isLivePhoto: live, burstID: nil,
                        isProtected: protected, isEligible: !protected)
    }

    private func analysis(_ asset: SuggestionAsset, digest: String? = nil) -> SuggestionAnalysis {
        SuggestionAnalysis(asset: asset, differenceHash: 0, featurePrint: Data(), hasPastEvent: false,
                           resourceDigest: digest, resourceBytes: digest == nil ? nil : 100,
                           checkedResources: digest != nil)
    }

    @Test("跨日期的原图和收藏修图版可一起比较，收藏版作为建议但不会自动决定")
    func distantFavoriteVersionRemainsOptional() {
        let original = asset("original"), edited = asset("favorite-export", days: 365, protected: true)
        let groups = SuggestionGrouping.build(assets: [edited, original], analyses: [
            original.id: analysis(original, digest: "original-resources"),
            edited.id: analysis(edited, digest: "edited-resources")
        ], now: date) { _, _ in 0.01 }
        #expect(groups.count == 1)
        #expect(Set(groups.first?.assetIDs ?? []) == [original.id, edited.id])
        #expect(groups.first?.reason == .possibleVersions)
        #expect(groups.first?.recommendedKeepID == edited.id)
        #expect(groups.first?.protectedIDs == [edited.id])
    }

    @Test("相同封面而视频未确认相同的 Live Photo 保持相似版本")
    func livePhotoPreviewDoesNotConfirmMotionResources() {
        let a = asset("motion-a", live: true), b = asset("motion-b", days: 7, live: true)
        // The scanner deliberately does not fingerprint Live Photo resources.
        let groups = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: analysis(a), b.id: analysis(b)], now: date) { _, _ in 0 }
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .similar)
        #expect(groups.first?.reason == .possibleVersions)
        #expect(groups.first?.recommendedKeepID == nil)
        #expect(groups.first?.knownBytes == nil)
    }

    @Test("完整资源确认的副本不吸收资源无法本机读取的相同预览")
    func unavailableResourcesCannotJoinConfirmedCopies() {
        let a = asset("local-a"), b = asset("local-b", days: 30), remote = asset("unreadable", days: 60)
        let groups = SuggestionGrouping.build(assets: [remote, b, a], analyses: [
            a.id: analysis(a, digest: "complete-resources"),
            b.id: analysis(b, digest: "complete-resources"),
            remote.id: analysis(remote)
        ], now: date) { _, _ in 0 }
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .duplicates)
        #expect(Set(groups.first?.assetIDs ?? []) == [a.id, b.id])
        #expect(groups.first?.knownBytes == 200)
    }
}
