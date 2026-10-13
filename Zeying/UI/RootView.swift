import Photos
import SwiftUI
import UIKit

struct RootView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore
    let suggestions: PhotoSuggestionService

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var selectedTab: RootTab = .home
    @State private var suggestionsOpenedFromHome = false
    @State private var homePath = NavigationPath()
    @State private var suggestionsPath = NavigationPath()
    @State private var settings = AppSettings()
    @State private var resume = ReviewResumeStore()
    // The first version could mark the guide as seen when its presentation was
    // interrupted by the authorization-to-loading transition. Offer the fixed
    // guide once more to installations that may have hit that path.
    @AppStorage("com.mars.zeying.hasSeenGuide.v2") private var hasSeenGuide = false

    private func usesRightTabRail(in geometry: GeometryProxy) -> Bool {
        guard verticalSizeClass == .compact,
              UIDevice.current.userInterfaceIdiom == .phone else { return false }
        if #available(iOS 27.1, *) {
            return geometry.reservedRegions(kind: .division, options: .includeInactive).isEmpty
        }
        return true
    }

    private func selectTab(_ tab: RootTab) {
        guard tab != selectedTab else { return }
        suggestions.deferAnalysisForInteraction()
        selectedTab = tab
    }

    var body: some View {
        Group {
            if shouldShowLoadingSplash {
                LoadingSplashView()
            } else if shouldShowFirstUseGuide {
                FirstUseGuideView(compact: true) { hasSeenGuide = true }
            } else {
                tabView
            }
        }
        .task(id: shouldStartLibraryLoad) {
            guard shouldStartLibraryLoad else { return }
            await library.ensureLoaded()
        }
        // Suggestions are prepared while the app is in use, so opening the
        // Suggestions tab can show useful results immediately. The service
        // still respects an explicit manual pause and the device power budget.
        .task(id: library.revision) {
            guard library.hasLoaded, scenePhase == .active else { return }
            suggestions.startIfNeeded(library: library, reviews: reviews)
            if !suggestions.hasScanned { suggestions.scheduleBackgroundCheck(after: 0) }
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
        .environment(suggestions)
        .environment(\.openSummaryTab, {
            homePath = NavigationPath()
            selectTab(.summary)
        })
        .environment(\.openPendingTab, {
            var path = NavigationPath()
            path.append(HomeDestination.pending)
            homePath = path
            selectTab(.home)
        })
        .environment(\.openHomeTab, {
            homePath = NavigationPath()
            selectTab(.home)
        })
        .environment(\.openReviewScope, { scope in
            var path = NavigationPath()
            path.append(HomeDestination.scope(scope))
            homePath = path
            selectTab(.home)
        })
        .onChange(of: scenePhase) { _, phase in
            suggestions.setForegroundActive(phase == .active)
            if phase == .inactive {
                if suggestions.isScanning { PhotoSuggestionForegroundGrace.begin(service: suggestions) }
            } else if phase == .background {
                library.stopReviewPrefetching()
                _ = reviews.flushPendingReviewChanges()
                suggestions.pause()
                PhotoSuggestionForegroundGrace.end()
                suggestions.scheduleBackgroundCheck(after: suggestions.hasScanned
                    ? PhotoSuggestionBackgroundTask.successfulScanDelay : 0)
            } else if phase == .active {
                library.updatePerformanceBudget()
                PhotoSuggestionForegroundGrace.end()
                PhotoSuggestionBackgroundTask.cancelRunning()
                suggestions.deferAnalysisForInteraction()
                if PHPhotoLibrary.authorizationStatus(for: .readWrite) != library.authorizationStatus {
                    Task { await library.refresh() }
                } else if library.hasLoaded {
                    suggestions.startIfNeeded(library: library, reviews: reviews)
                }
            }
        }
        .onChange(of: suggestions.isScanning) { _, scanning in
            if !scanning {
                PhotoSuggestionForegroundGrace.end()
                // A PhotoKit refresh may arrive during a long scan. Finish
                // that pass first, then check the newest library snapshot.
                if scenePhase == .active && library.hasLoaded {
                    suggestions.startIfNeeded(library: library, reviews: reviews)
                }
            }
        }
        .onChange(of: selectedTab) { previous, current in
            if previous == .suggestions && current != .suggestions {
                suggestionsOpenedFromHome = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            library.updatePerformanceBudget()
            if scenePhase == .active && library.hasLoaded {
                suggestions.startIfNeeded(library: library, reviews: reviews)
            }
            suggestions.scheduleBackgroundCheck(after: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            if scenePhase == .active && library.hasLoaded {
                suggestions.startIfNeeded(library: library, reviews: reviews)
            }
            suggestions.scheduleBackgroundCheck(after: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            library.updatePerformanceBudget()
            if scenePhase == .active && library.hasLoaded {
                suggestions.startIfNeeded(library: library, reviews: reviews)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            library.updatePerformanceBudget(memoryWarning: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await library.refresh() }
        }
        .tint(.primary)
    }

    private var tabView: some View {
        GeometryReader { geometry in
            let foldedPortraitHeaderInset: CGFloat = {
                guard #available(iOS 27.1, *),
                      UIDevice.current.userInterfaceIdiom == .phone,
                      geometry.size.height > geometry.size.width else { return 0 }
                let hasTrailingCamera = geometry.reservedRegions(kind: .occlusion)
                    .contains { region in
                        region.isActive && region.frame.midX > geometry.size.width / 2 &&
                            region.frame.minY < geometry.size.height / 4
                    }
                return hasTrailingCamera ? 24 : 0
            }()
            let expandedFold: Bool = {
                guard #available(iOS 27.1, *),
                      UIDevice.current.userInterfaceIdiom == .phone,
                      geometry.size.width > geometry.size.height else { return false }
                return geometry.reservedRegions(kind: .division, options: .includeInactive)
                    .contains { $0.frame.minX > 0 && $0.frame.maxX < geometry.size.width }
            }()
            if verticalSizeClass == .compact && UIDevice.current.userInterfaceIdiom == .phone {
                let showRightTabRail = usesRightTabRail(in: geometry)
                HStack(spacing: 0) {
                    nativeTabView(showRightTabRail: showRightTabRail)
                        .environment(\.zeyingFoldedPortraitHeaderInset, foldedPortraitHeaderInset)
                        .environment(\.zeyingExpandedFold, expandedFold)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showRightTabRail { rightTabRail }
                }
                .ignoresSafeArea(.container, edges: showRightTabRail ? .trailing : [])
            } else {
                nativeTabView(showRightTabRail: false)
                    .environment(\.zeyingFoldedPortraitHeaderInset, foldedPortraitHeaderInset)
                    .environment(\.zeyingExpandedFold, expandedFold)
            }
        }
    }

    private func nativeTabView(showRightTabRail: Bool) -> some View {
        TabView(selection: Binding(
            get: { selectedTab },
            set: { tab in
                selectTab(tab)
            }
        )) {
            NavigationStack(path: $homePath) {
                LibraryHomeView(
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments,
                    onOpenSummary: {
                        homePath = NavigationPath()
                        selectTab(.summary)
                    },
                    onOpenSuggestions: {
                        suggestionsOpenedFromHome = true
                        selectTab(.suggestions)
                    }
                )
            }
            .toolbar(showRightTabRail ? .hidden : .automatic, for: .tabBar)
            .tabItem {
                Label(String(localized: "整理"), systemImage: "square.stack.3d.up")
            }
            .tag(RootTab.home)

            NavigationStack(path: $suggestionsPath) {
                SuggestionsView(
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments,
                    showsBackToHome: suggestionsOpenedFromHome,
                    isFullScreenReview: !suggestionsPath.isEmpty,
                    onBackToHome: {
                        homePath = NavigationPath()
                        selectTab(.home)
                    }
                )
            }
            .toolbar(showRightTabRail ? .hidden : .automatic, for: .tabBar)
            .tabItem {
                Label(String(localized: "清理建议"), systemImage: "wand.and.stars")
            }
            .tag(RootTab.suggestions)

            NavigationStack {
                ReviewSummaryView(
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments
                )
            }
            .toolbar(showRightTabRail ? .hidden : .automatic, for: .tabBar)
            .tabItem {
                Label(String(localized: "清单"), systemImage: "checklist")
            }
            .tag(RootTab.summary)

            NavigationStack {
                SettingsView(library: library, reviews: reviews)
            }
            .toolbar(showRightTabRail ? .hidden : .automatic, for: .tabBar)
            .tabItem {
                Label(String(localized: "设置"), systemImage: "gearshape")
            }
            .tag(RootTab.settings)
        }
    }

    private var rightTabRail: some View {
        VStack(spacing: 6) {
            rightTabButton(.home, symbol: "square.stack.3d.up", title: String(localized: "整理"))
            rightTabButton(.suggestions, symbol: "wand.and.stars", title: String(localized: "清理建议"))
            rightTabButton(.summary, symbol: "checklist", title: String(localized: "清单"))
            rightTabButton(.settings, symbol: "gearshape", title: String(localized: "设置"))
        }
        .padding(6)
        .zeyingGlass(in: Capsule())
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }

    private func rightTabButton(_ tab: RootTab, symbol: String, title: String) -> some View {
        Button {
            selectTab(tab)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 50, height: 50)
                .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                .background {
                    if selectedTab == tab {
                        Circle().fill(Color(uiColor: .tertiarySystemFill))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
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
    case suggestions
    case summary
    case settings
}

private struct OpenSummaryTabKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

private struct OpenPendingTabKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

private struct OpenHomeTabKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

private struct OpenReviewScopeKey: EnvironmentKey {
    static var defaultValue: (@MainActor (LibraryScope) -> Void)? { nil }
}

extension EnvironmentValues {
    var openHomeTab: (@MainActor () -> Void)? {
        get { self[OpenHomeTabKey.self] }
        set { self[OpenHomeTabKey.self] = newValue }
    }
    var openReviewScope: (@MainActor (LibraryScope) -> Void)? {
        get { self[OpenReviewScopeKey.self] }
        set { self[OpenReviewScopeKey.self] = newValue }
    }
    var openPendingTab: (@MainActor () -> Void)? {
        get { self[OpenPendingTabKey.self] }
        set { self[OpenPendingTabKey.self] = newValue }
    }
    var openSummaryTab: (@MainActor () -> Void)? {
        get { self[OpenSummaryTabKey.self] }
        set { self[OpenSummaryTabKey.self] = newValue }
    }
}
