import Foundation

struct ReviewAlbumSnapshot: Equatable {
    let albumIdentifier: String?
    let albumTitle: String

    @MainActor
    static func capture(for identifier: String, in store: PendingAlbumAssignmentStore) -> Self? {
        guard let assignment = store.assignment(for: identifier) else { return nil }
        return Self(albumIdentifier: assignment.albumIdentifier, albumTitle: assignment.albumTitle)
    }
}

/// Restores the decision and its staged album together. A stale queue action
/// must never change either record.
@MainActor
enum ReviewUndoCoordinator {
    static func undo(
        token: UUID,
        assetIdentifier: String,
        previousAlbum: ReviewAlbumSnapshot?,
        reviews: ReviewStore,
        albums: PendingAlbumAssignmentStore
    ) -> Bool {
        guard reviews.latestUndoToken == token else { return false }
        let currentAlbum = ReviewAlbumSnapshot.capture(for: assetIdentifier, in: albums)
        guard restore(previousAlbum, for: assetIdentifier, in: albums) else { return false }
        guard reviews.undo(matching: token) else {
            _ = restore(currentAlbum, for: assetIdentifier, in: albums)
            return false
        }
        return true
    }

    private static func restore(
        _ snapshot: ReviewAlbumSnapshot?,
        for identifier: String,
        in albums: PendingAlbumAssignmentStore
    ) -> Bool {
        if let snapshot {
            return albums.assign(
                assetIdentifier: identifier,
                albumIdentifier: snapshot.albumIdentifier,
                albumTitle: snapshot.albumTitle
            )
        }
        return albums.remove(assetIdentifier: identifier)
    }
}
