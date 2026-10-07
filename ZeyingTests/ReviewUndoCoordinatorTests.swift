import Foundation
import SwiftData
import Testing
@testable import Zeying

@MainActor
struct ReviewUndoCoordinatorTests {
    @Test("撤销首次相簿选择时同时移除保留决定和相簿待办")
    func firstAlbumChoiceRestoresUnreviewedState() throws {
        let (reviews, albums) = try stores()
        #expect(albums.assign(assetIdentifier: "photo", albumIdentifier: "trip", albumTitle: "旅行"))
        #expect(reviews.decide(.keep, for: "photo"))
        let token = try #require(reviews.latestUndoToken)

        #expect(ReviewUndoCoordinator.undo(token: token, assetIdentifier: "photo", previousAlbum: nil,
            reviews: reviews, albums: albums))
        #expect(reviews.decision(for: "photo") == nil)
        #expect(albums.assignment(for: "photo") == nil)
    }

    @Test("撤销重新决定时恢复此前收藏及相簿目标")
    func undoRestoresPreviousFavoriteAndAlbum() throws {
        let (reviews, albums) = try stores()
        #expect(reviews.stageFavorite(for: "photo", alreadyFavorite: false))
        #expect(albums.assign(assetIdentifier: "photo", albumIdentifier: "family", albumTitle: "家人"))
        let previous = ReviewAlbumSnapshot.capture(for: "photo", in: albums)
        #expect(albums.remove(assetIdentifier: "photo"))
        #expect(reviews.decide(.delete, for: "photo"))
        let token = try #require(reviews.latestUndoToken)

        #expect(ReviewUndoCoordinator.undo(token: token, assetIdentifier: "photo", previousAlbum: previous,
            reviews: reviews, albums: albums))
        #expect(reviews.decision(for: "photo") == .keep)
        #expect(reviews.isPendingFavorite("photo"))
        #expect(albums.assignment(for: "photo")?.albumIdentifier == "family")
    }

    @Test("过期撤销令牌不修改决定或相簿待办")
    func staleTokenCannotMutateRecords() throws {
        let (reviews, albums) = try stores()
        #expect(reviews.decide(.keep, for: "photo"))
        let stale = try #require(reviews.latestUndoToken)
        #expect(reviews.decide(.later, for: "other"))
        #expect(albums.assign(assetIdentifier: "photo", albumIdentifier: "trip", albumTitle: "旅行"))

        #expect(!ReviewUndoCoordinator.undo(token: stale, assetIdentifier: "photo", previousAlbum: nil,
            reviews: reviews, albums: albums))
        #expect(reviews.decision(for: "photo") == .keep)
        #expect(reviews.decision(for: "other") == .later)
        #expect(albums.assignment(for: "photo")?.albumIdentifier == "trip")
    }

    private func stores() throws -> (ReviewStore, PendingAlbumAssignmentStore) {
        let container = try ModelContainer(
            for: ReviewRecord.self, PendingAlbumAssignment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaults = UserDefaults(suiteName: "ReviewUndoTests.\(UUID().uuidString)")!
        return (ReviewStore(context: container.mainContext, defaults: defaults),
                PendingAlbumAssignmentStore(context: container.mainContext))
    }
}
