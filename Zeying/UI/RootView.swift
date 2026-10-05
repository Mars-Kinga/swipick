import Photos
import SwiftUI

struct RootView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: RootTab = .home
    @State private var homePath = NavigationPath()
    @State private var settings = AppSettings()
    @State private var resume = ReviewResumeStore()
    // The first version could mark the guide as seen when its presentation was
    // interrupted by the authorization-to-loading transition. Offer the fixed
    // guide once more to installations that may have hit that path.
    @AppStorage("com.mars.zeying.hasSeenGuide.v2") private var hasSeenGuide = false

    var body: some View {
        Group {
            if shouldShowLoadingSplash {
                LoadingSplashView()
            } else if shouldShowFirstUseGuide {
                FirstUseGuideView { hasSeenGuide = true }
            } else {
                tabView
            }
        }
        .task(id: shouldStartLibraryLoad) {
            guard shouldStartLibraryLoad else { return }
            await library.ensureLoaded()
        }
        .task(id: library.hasLoaded) {
            guard library.hasLoaded,
                  !LivePhotoConversionManager.shared.pendingConversions.isEmpty else { return }
            await LivePhotoConversionManager.shared.reconcile(
                library: library,
                reviews: reviews,
                albumAssignments: albumAssignments
            )
        }
        .environment(settings)
        .environment(resume)
        .environment(\.openSummaryTab, {
            homePath = NavigationPath()
            selectedTab = .summary
        })
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                _ = reviews.flushPendingReviewChanges()
            }
        }
        .tint(.primary)
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                LibraryHomeView(
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments,
                    onOpenSummary: {
                        homePath = NavigationPath()
                        selectedTab = .summary
                    }
                )
            }
            .tabItem {
                Label(String(localized: "整理"), systemImage: "square.stack.3d.up")
            }
            .tag(RootTab.home)

            NavigationStack {
                PendingDecisionsView(
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments
                )
            }
            .tabItem {
                Label(String(localized: "待决定"), systemImage: "questionmark.circle")
            }
            .tag(RootTab.pending)

            NavigationStack {
                ReviewSummaryView(
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments
                )
            }
            .tabItem {
                Label(String(localized: "清单"), systemImage: "checklist")
            }
            .tag(RootTab.summary)

            NavigationStack {
                SettingsView(library: library, reviews: reviews)
            }
            .tabItem {
                Label(String(localized: "设置"), systemImage: "gearshape")
            }
            .tag(RootTab.settings)
        }
    }

    private var shouldStartLibraryLoad: Bool {
        switch library.authorizationStatus {
        case .authorized, .limited:
            !library.hasLoaded
        default:
            false
        }
    }

    private var shouldShowLoadingSplash: Bool {
        shouldStartLibraryLoad
    }

    private var shouldShowFirstUseGuide: Bool {
        guard !hasSeenGuide, library.hasLoaded else { return false }
        switch library.authorizationStatus {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }
}

private enum RootTab: Hashable {
    case home
    case pending
    case summary
    case settings
}

private struct OpenSummaryTabKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

extension EnvironmentValues {
    var openSummaryTab: (@MainActor () -> Void)? {
        get { self[OpenSummaryTabKey.self] }
        set { self[OpenSummaryTabKey.self] = newValue }
    }
}
