import Testing
@testable import Zeying

struct SuggestionRecommendedOrderingTests {
    @Test("Confirmed copies precede similar versions and screenshots despite learning history")
    func safetyCategoryOrder() {
        var learning = SuggestionOrderLearning()
        for _ in 0..<100 {
            learning.recordSkip(reason: .identicalResources)
            learning.recordCompletion(reason: .olderScreenshots, kept: 0, total: 2)
        }
        let screenshot = group("screen", .screenshots, .olderScreenshots)
        let similar = group("similar", .similar, .possibleVersions)
        let duplicate = group("copy", .duplicates, .identicalResources)
        let sorted = SuggestionRecommendedOrdering.sorted([screenshot, similar, duplicate], learning: learning)
        #expect(sorted.map(\.id) == ["copy", "similar", "screen"])
    }

    @Test("Learning reorders reasons within the same category and preserves ties")
    func withinCategoryOrder() {
        var learning = SuggestionOrderLearning()
        learning.recordCompletion(reason: .nearbyShots, kept: 1, total: 2)
        let groups = [group("versions", .similar, .possibleVersions),
                      group("shots-1", .similar, .nearbyShots), group("shots-2", .similar, .nearbyShots)]
        #expect(SuggestionRecommendedOrdering.sorted(groups, learning: learning).map(\.id) == ["shots-1", "shots-2", "versions"])
    }

    private func group(_ id: String, _ kind: SuggestionKind, _ reason: SuggestionReason) -> CleanupSuggestion {
        CleanupSuggestion(id: id, kind: kind, reason: reason, assetIDs: [id + "1", id + "2"],
                          recommendedKeepID: nil, protectedIDs: [], knownBytes: nil, newestDate: nil)
    }
}
