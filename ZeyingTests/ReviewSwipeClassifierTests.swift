import CoreGraphics
import Testing
@testable import Zeying

struct ReviewSwipeClassifierTests {
    @Test("下滑必须够长且方向明确，短滑和斜滑不会标记待决定")
    func undecidedNeedsDeliberateDownwardDrag() {
        #expect(ReviewSwipeClassifier.axis(for: CGSize(width: 8, height: 30)) == .downward)
        #expect(!ReviewSwipeClassifier.commitsUndecided(CGSize(width: 0, height: 120)))
        #expect(!ReviewSwipeClassifier.commitsUndecided(CGSize(width: 115, height: 170)))
        #expect(!ReviewSwipeClassifier.commitsUndecided(CGSize(width: 0, height: -180)))
        #expect(ReviewSwipeClassifier.commitsUndecided(CGSize(width: 24, height: 180)))
    }

    @Test("横滑与下滑方向在手势开始后不会因小幅斜向移动混淆")
    func swipeAxisIsUnambiguous() {
        #expect(ReviewSwipeClassifier.axis(for: CGSize(width: 30, height: 4)) == .horizontal)
        #expect(ReviewSwipeClassifier.axis(for: CGSize(width: 20, height: 20)) == nil)
        #expect(ReviewSwipeClassifier.axis(for: CGSize(width: 0, height: -40)) == nil)
    }
}
