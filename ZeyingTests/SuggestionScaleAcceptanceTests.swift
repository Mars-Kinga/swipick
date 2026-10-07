import Foundation
import Testing
@testable import Zeying

struct SuggestionScaleAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func fixture(_ count: Int) -> ([SuggestionAsset], [String: SuggestionAnalysis]) {
        let assets = (0..<count).map { index in
            SuggestionAsset(id: String(format: "photo-%04d", index), modifiedAt: now,
                            createdAt: now.addingTimeInterval(Double(index) * 120),
                            width: 1200, height: 1600, isScreenshot: false, isLivePhoto: false,
                            burstID: nil, isProtected: false, isEligible: true)
        }
        let analyses = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.id, SuggestionAnalysis(asset: $0, differenceHash: 0, featurePrint: Data(), hasPastEvent: false))
        })
        return (assets, analyses)
    }

    @Test("同哈希的数百张候选仍覆盖后段照片，且每张只出现一次")
    func crowdedHashBucketCoversEntireLibrary() {
        let (assets, analyses) = fixture(256)
        let groups = SuggestionGrouping.build(assets: assets, analyses: analyses, now: now) { _, _ in 0.01 }
        let ids = groups.flatMap(\.assetIDs)
        #expect(Set(ids) == Set(assets.map(\.id)))
        #expect(ids.count == Set(ids).count)
        #expect(groups.count == 1)
        #expect(groups.first?.assetIDs.count == 256)
    }

    @Test("哈希碰撞较多时仍可找到桶后段唯一的视觉相近对")
    func latePairSurvivesEarlierHashCollisions() {
        let (assets, analyses) = fixture(256)
        let pair = Set([assets[254].id, assets[255].id])
        let groups = SuggestionGrouping.build(assets: assets, analyses: analyses, now: now) { left, right in
            Set([left, right]) == pair ? Float(0.01) : Float(1)
        }
        #expect(groups.count == 1)
        #expect(Set(groups.first?.assetIDs ?? []) == pair)
    }

    @Test("相同图库输入顺序改变不影响建议排序或分组")
    func resultsRemainDeterministicAcrossInputOrder() {
        let (assets, analyses) = fixture(120)
        let forward = SuggestionGrouping.build(assets: assets, analyses: analyses, now: now) { _, _ in 0.01 }
        let reverse = SuggestionGrouping.build(assets: Array(assets.reversed()), analyses: analyses, now: now) { _, _ in 0.01 }
        #expect(forward == reverse)
        #expect(Set(forward.flatMap(\.assetIDs)).count == assets.count)
    }
}
