import SwiftData
import SwiftUI
import UIKit

@main
@MainActor
struct ZeyingApp: App {
    private let appState = AppState()

    var body: some Scene {
        WindowGroup {
            if let reviews = appState.reviews,
               let albumAssignments = appState.albumAssignments {
                RootView(
                    library: appState.library,
                    reviews: reviews,
                    sizes: appState.sizes,
                    albumService: appState.albumService,
                    albumAssignments: albumAssignments,
                    suggestions: appState.suggestions
                )
            } else {
                ContentUnavailableView(
                    String(localized: "无法打开择影"),
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(appState.startupError ?? String(localized: "本机数据库无法打开。"))
                )
            }
        }
    }
}

@MainActor
private final class AppState {
    private let modelContainer: ModelContainer?
    let library = PhotoLibraryService()
    let albumService = PhotoAlbumService()
    let sizes = AssetSizeService()
    let suggestions = PhotoSuggestionService()
    let reviews: ReviewStore?
    let albumAssignments: PendingAlbumAssignmentStore?
    let startupError: String?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        do {
            let container = try ModelContainer(for: ReviewRecord.self, PendingAlbumAssignment.self)
            modelContainer = container
            reviews = ReviewStore(context: container.mainContext)
            let assignments = PendingAlbumAssignmentStore(context: ModelContext(container))
            albumAssignments = assignments
            startupError = nil
            suggestions.setAlbumAssignments(assignments)
            if let reviews {
                PhotoSuggestionBackgroundTask.register(service: suggestions, library: library, reviews: reviews)
            }
        } catch {
            modelContainer = nil
            reviews = nil
            albumAssignments = nil
            startupError = String(localized: "无法读取本机处理进度：\(error.localizedDescription)")
        }
    }
}
