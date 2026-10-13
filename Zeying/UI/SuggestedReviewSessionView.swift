import Photos
import SwiftUI

struct SuggestionPaneUndoState {
    var isVisible = false
    var isEnabled = false
    var title = ""

    static let hidden = SuggestionPaneUndoState()
}

struct SuggestedReviewSessionView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore
    let incomingGroups: [CleanupSuggestion]
    let selection: Binding<String?>?
    let paneUndoState: Binding<SuggestionPaneUndoState>?
    let paneUndoRequest: Int?
    let paneSkipRequest: Int?

    @Environment(PhotoSuggestionService.self) private var suggestions
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSummaryTab) private var openSummaryTab
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.reviewInNarrowPane) private var reviewInNarrowPane
    @Environment(\.zeyingExpandedFold) private var expandedFold
    @Environment(\.zeyingFoldedPortraitHeaderInset) private var foldedPortraitHeaderInset
    @State private var groups: [CleanupSuggestion]
    @State private var index: Int
    @State private var keeping = Set<String>()
    @State private var didInitializeSelection = false
    @State private var groupDrafts: [String: Set<String>] = [:]
    @State private var undoEntries: [(index: Int, token: UUID, wholeGroup: Bool, learnedKept: Int?)] = []
    @State private var startedUndoToken: UUID?
    @State private var gallery: SuggestionGallerySelection?
    @State private var showingError = false

    init(groups: [CleanupSuggestion], startingAt startGroup: CleanupSuggestion? = nil,
         library: PhotoLibraryService, reviews: ReviewStore, sizes: AssetSizeService,
         albumService: PhotoAlbumService, albumAssignments: PendingAlbumAssignmentStore,
         selection: Binding<String?>? = nil,
         paneUndoState: Binding<SuggestionPaneUndoState>? = nil, paneUndoRequest: Int? = nil,
         paneSkipRequest: Int? = nil) {
        _groups = State(initialValue: groups)
        _index = State(initialValue: SuggestionReviewQueue.initialIndex(of: startGroup, in: groups))
        self.incomingGroups = groups
        self.selection = selection
        self.paneUndoState = paneUndoState
        self.paneUndoRequest = paneUndoRequest
        self.paneSkipRequest = paneSkipRequest
        self.library = library
        self.reviews = reviews
        self.sizes = sizes
        self.albumService = albumService
        self.albumAssignments = albumAssignments
    }

    private var group: CleanupSuggestion? { groups.indices.contains(index) ? groups[index] : nil }
    private var currentAssets: [PHAsset] {
        group.map { SuggestionReviewQueue.orderedAssetIDs(in: $0).compactMap { library.asset(with: $0) } } ?? []
    }
    private var protectedIDs: Set<String> {
        Set(currentAssets.filter {
            $0.isFavorite || reviews.isPendingFavorite($0.localIdentifier) ||
            albumAssignments.assignment(for: $0.localIdentifier) != nil
        }.map(\.localIdentifier))
    }
    private var selectedIDs: Set<String> { keeping.union(protectedIDs).intersection(Set(currentAssets.map(\.localIdentifier))) }
    private var canChooseKeepers: Bool {
        guard let group else { return false }
        return !currentAssets.isEmpty && currentAssets.count == group.assetIDs.count &&
            suggestions.isCurrent(group, library: library) &&
            !group.assetIDs.contains { reviews.decision(for: $0) == .delete || reviews.decision(for: $0) == .later }
    }
    private var canCommit: Bool {
        guard let group else { return false }
        return !selectedIDs.isEmpty && currentAssets.count == group.assetIDs.count
    }
    private var canKeepAll: Bool {
        guard let group else { return false }
        return currentAssets.count == group.assetIDs.count &&
            suggestions.isCurrent(group, library: library) &&
            !group.assetIDs.contains { reviews.decision(for: $0) == .delete || reviews.decision(for: $0) == .later }
    }
    private var canKeepNone: Bool { canKeepAll && protectedIDs.isEmpty }
    private var canUndo: Bool { undoEntries.last.map { reviews.latestUndoToken == $0.token } ?? false }
    private var pendingConfirmationCount: Int {
        let deletions = reviews.identifiers(with: .delete)
            .filter { library.asset(with: $0) != nil }
            .count
        let favorites = reviews.pendingFavoriteIdentifiers
            .filter { library.asset(with: $0) != nil }
            .count
        return deletions + favorites + albumAssignments.count +
            LivePhotoConversionManager.shared.visiblePendingConversions(reviews: reviews).count +
            (LivePhotoConversionManager.shared.journalError == nil ? 0 : 1)
    }
    private var undoTitle: String {
        String(localized: undoEntries.last?.wholeGroup == false ? "撤销上一张" : "撤销整组决定")
    }

    private var usesExpandedCompletionLayout: Bool {
        (reviewInNarrowPane || horizontalSizeClass == .regular || verticalSizeClass == .compact) &&
            !dynamicTypeSize.isAccessibilitySize
    }

    private var usesExpandedComparisonLayout: Bool {
        !reviewInNarrowPane && (horizontalSizeClass == .regular || verticalSizeClass == .compact) &&
            !dynamicTypeSize.isAccessibilitySize
    }

    private var showsExpandedComparisonHeader: Bool {
        usesExpandedComparisonLayout && group != nil
    }

    private var showsFoldedComparisonHeader: Bool {
        foldedPortraitHeaderInset > 0 && !usesExpandedComparisonLayout && !reviewInNarrowPane && group != nil
    }

    private var comparisonTopPadding: CGFloat {
        if showsFoldedComparisonHeader { return 4 + foldedPortraitHeaderInset }
        if reviewInNarrowPane {
            if expandedFold { return 30 }
            if verticalSizeClass == .compact { return 76 }
            return 60
        }
        return selection == nil ? 20 : 0
    }

    private var sheetGallery: Binding<SuggestionGallerySelection?> {
        Binding(get: { expandedFold ? nil : gallery }, set: { gallery = $0 })
    }

    private var fullScreenGallery: Binding<SuggestionGallerySelection?> {
        Binding(get: { expandedFold ? gallery : nil }, set: { gallery = $0 })
    }

    var body: some View {
        Group {
            if let group, group.kind == .screenshots {
                ReviewQueueView(
                    assetIDs: currentAssets.filter { reviews.decision(for: $0.localIdentifier) == nil && !protectedIDs.contains($0.localIdentifier) }.map(\.localIdentifier),
                    suggestedTitle: group.displayTitle, suggestedReason: group.reason.title,
                    onCompletion: { finishScreenshots() }, library: library, reviews: reviews, sizes: sizes,
                    albumService: albumService, albumAssignments: albumAssignments
                )
                .id(group.id)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if !reviewInNarrowPane, !undoEntries.isEmpty {
                            Button(undoTitle, systemImage: "arrow.uturn.backward") { undo() }
                                .disabled(!canUndo)
                        }
                    }
                }
            } else {
                comparisonContent
                    .navigationTitle(selection == nil && !usesExpandedComparisonLayout && !showsFoldedComparisonHeader
                                     ? String(localized: "推荐审核") : "")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar((showsExpandedComparisonHeader && !expandedFold) || reviewInNarrowPane
                             ? .hidden : .visible,
                             for: .navigationBar)
                    .toolbar {
                        if !reviewInNarrowPane && (expandedFold || showsFoldedComparisonHeader) {
                            if !undoEntries.isEmpty {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(undoTitle, systemImage: "arrow.uturn.backward") { undo() }
                                        .labelStyle(.iconOnly)
                                        .disabled(!canUndo)
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(String(localized: "跳过本组"), systemImage: "forward.end") { skip() }
                                    .labelStyle(.iconOnly)
                            }
                        } else if !showsExpandedComparisonHeader {
                            comparisonToolbar
                        }
                    }
            }
        }
        .onAppear {
            if !didInitializeSelection, let group {
                keeping = initialSelection(for: group)
                didInitializeSelection = true
            }
            startedUndoToken = reviews.latestUndoToken
            rememberSession()
            selection?.wrappedValue = group?.id
            publishPaneUndoState()
        }
        .onChange(of: undoEntries.count) { _, _ in publishPaneUndoState() }
        .onChange(of: reviews.latestUndoToken) { _, _ in publishPaneUndoState() }
        .onChange(of: paneUndoRequest) { oldValue, newValue in
            if reviewInNarrowPane, oldValue != newValue, newValue != nil { undo() }
        }
        .onChange(of: paneSkipRequest) { oldValue, newValue in
            if reviewInNarrowPane, oldValue != newValue, newValue != nil { skip() }
        }
        .onChange(of: selection?.wrappedValue) { _, selectedID in
            guard let selectedID = selectedID ?? incomingGroups.first?.id,
                  group?.id != selectedID else { return }
            if let current = group { groupDrafts[current.id] = keeping }
            if let target = groups.firstIndex(where: { $0.id == selectedID }) {
                index = target
            } else if let incoming = incomingGroups.first(where: { $0.id == selectedID }) {
                groups.append(incoming)
                index = groups.count - 1
            } else {
                return
            }
            gallery = nil
            keeping = group.map { initialSelection(for: $0) } ?? []
            startedUndoToken = reviews.latestUndoToken
            rememberSession()
        }
        .onChange(of: suggestions.groups) { _, refreshed in
            let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
            groups = groups.map { byID[$0.id] ?? $0 }
        }
        .task(id: group?.id) {
            if let group { await suggestions.prioritizeRecommendation(for: group, library: library) }
        }
        .task(id: index, priority: .utility) { await prefetchNeighboringGroups() }
        .sheet(item: sheetGallery) { selection in galleryContent(selection) }
        .fullScreenCover(item: fullScreenGallery) { selection in galleryContent(selection) }
        .alert(String(localized: "操作未完成"), isPresented: $showingError) {
            Button(String(localized: "知道了"), role: .cancel) { reviews.clearError() }
        } message: {
            Text(reviews.errorMessage ?? String(localized: "照片或处理状态已变化，请重新检查这一组。"))
        }
    }

    @ViewBuilder
    private func galleryContent(_ selection: SuggestionGallerySelection) -> some View {
        if let group {
            SuggestionPhotoGallery(group: group, assetIDs: currentAssets.map(\.localIdentifier),
                                   initialID: selection.id, library: library, sizes: sizes,
                                   keeping: $keeping, protectedIDs: protectedIDs,
                                   hasNextGroup: groups.indices.contains(index + 1),
                                   canAdvance: canCommit, canKeepAll: canKeepAll,
                                   canKeepNone: canKeepNone, expandedFold: expandedFold,
                                   foldedPortraitHeaderInset: foldedPortraitHeaderInset) { choice in
                let saved: Bool
                switch choice {
                case .selected: saved = commit(keeping: selectedIDs)
                case .all: saved = commit(keeping: Set(group.assetIDs))
                case .none: saved = commit(keeping: [], allowEmptyKeep: true)
                }
                guard saved else { return .failed }
                guard let nextGroup = self.group, nextGroup.kind != .screenshots,
                      let first = currentAssets.first?.localIdentifier else { return .dismiss }
                return .next(first)
            }
        }
    }

    @ViewBuilder
    private var comparisonContent: some View {
        if let group {
            if usesExpandedComparisonLayout {
                GeometryReader { geometry in
                    let division: CGRect? = {
                        guard expandedFold, #available(iOS 27.1, *) else { return nil }
                        return geometry.reservedRegions(kind: .division, options: .includeInactive)
                            .map(\.frame)
                            .first { $0.minX > 0 && $0.maxX < geometry.size.width }
                    }()
                    let leftPaneWidth = division.map { max(0, $0.minX - 40) }
                    let rightPaneWidth = division.map { max(0, geometry.size.width - $0.maxX - 40) }
                    let paneWidth = rightPaneWidth ?? max(0, (geometry.size.width - 120) / 2)
                    let foldClearance = division.map { $0.width + 40 } ?? 80

                    ScrollView(.vertical) {
                        LazyVStack(spacing: 16) {
                            if currentAssets.count != group.assetIDs.count {
                                Label(String(localized: "部分照片已无法访问，请跳过本组并更新建议。"), systemImage: "exclamationmark.triangle")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(0..<((currentAssets.count + 3) / 4), id: \.self) { row in
                                let rowAssets = Array(currentAssets.dropFirst(row * 4).prefix(4))
                                HStack(alignment: .top, spacing: 0) {
                                    expandedPhotoPair(Array(rowAssets.prefix(2)), group: group)
                                        .frame(width: leftPaneWidth, alignment: .leading)
                                        .frame(maxWidth: leftPaneWidth == nil ? .infinity : nil, alignment: .topLeading)
                                    Color.clear.frame(width: foldClearance)
                                        .allowsHitTesting(false)
                                    expandedPhotoPair(Array(rowAssets.dropFirst(2)), group: group)
                                        .frame(width: rightPaneWidth, alignment: .leading)
                                        .frame(maxWidth: rightPaneWidth == nil ? .infinity : nil, alignment: .topLeading)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 80)
                        .padding(.bottom, 88)
                    }
                    .scrollIndicators(.visible)
                    .scrollBounceBehavior(.always)
                    .simultaneousGesture(groupBrowsingGesture)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(alignment: .top) {
                        expandedComparisonHeader(for: group)
                            .frame(maxWidth: .infinity)
                            .background(Color(uiColor: .systemBackground))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        expandedComparisonActions(for: group)
                            .frame(width: paneWidth)
                            .padding(.trailing, 20)
                            .padding(.bottom, 16)
                    }
                    .accessibilityAction(named: String(localized: "上一组")) { browseGroup(-1) }
                    .accessibilityAction(named: String(localized: "下一组")) { browseGroup(1) }
                }
                .id(group.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: reviewInNarrowPane ? 2 : 8) {
                            Text(reviewInNarrowPane
                                 ? "\(index + 1)/\(groups.count)"
                                 : "\(index + 1) / \(groups.count) · \(group.displayTitle)")
                                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            Text(String(localized: "选择要保留的照片"))
                                .font(.title2.weight(.bold))
                        }
                        if currentAssets.count != group.assetIDs.count {
                            Label(String(localized: "部分照片已无法访问，请跳过本组并更新建议。"), systemImage: "exclamationmark.triangle")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: comparisonColumns, spacing: 16) {
                            ForEach(currentAssets, id: \.localIdentifier) { asset in photoCell(asset, group: group) }
                        }
                    }
                    .padding(.horizontal, 20)
                    // The expanded Duo pane leaves room for the status area at
                    // the right, while its title can sit alongside the Wi-Fi icon.
                    .padding(.top, comparisonTopPadding)
                    .padding(.bottom, 20)
                }
                .id(group.id)
                .transition(.opacity)
                .simultaneousGesture(groupBrowsingGesture)
                .accessibilityAction(named: String(localized: "上一组")) { browseGroup(-1) }
                .accessibilityAction(named: String(localized: "下一组")) { browseGroup(1) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    comparisonActions(for: group, inSideBar: false)
                }
            }
        } else {
            completedContent
        }
    }

    private var groupBrowsingGesture: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            let horizontal = value.translation.width
            let vertical = value.translation.height
            guard abs(horizontal) >= 70, abs(horizontal) > abs(vertical) * 1.4,
                  horizontal < 0 || value.startLocation.x > 36 else { return }
            browseGroup(horizontal < 0 ? 1 : -1)
        }
    }

    private func expandedComparisonHeader(for group: CleanupSuggestion) -> some View {
        HStack(spacing: 14) {
            if !expandedFold {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .zeyingGlass(in: Capsule())
                .padding(5)
                .accessibilityLabel(String(localized: "返回建议"))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1) / \(groups.count) · \(group.displayTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(String(localized: "选择要保留的照片"))
                    .font(.title3.weight(.bold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !expandedFold {
                HStack(spacing: 4) {
                    if !undoEntries.isEmpty {
                        Button(undoTitle, systemImage: "arrow.uturn.backward") { undo() }
                            .labelStyle(.iconOnly)
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Capsule())
                            .buttonStyle(.plain)
                            .disabled(!canUndo)
                    }

                    Button(String(localized: "跳过本组"), systemImage: "forward.end") { skip() }
                        .labelStyle(.iconOnly)
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Capsule())
                        .buttonStyle(.plain)
                }
                .zeyingGlass(in: Capsule())
                .padding(5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func expandedPhotoPair(_ assets: [PHAsset], group: CleanupSuggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<2, id: \.self) { column in
                if assets.indices.contains(column) {
                    photoCell(assets[column], group: group)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    Color.clear.frame(maxWidth: .infinity).allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func expandedComparisonActions(for group: CleanupSuggestion) -> some View {
        let canDeleteAll = canKeepNone && selectedIDs.isEmpty
        let canActivate = selectedIDs.isEmpty ? canChooseKeepers : canCommit

        return HStack(spacing: 4) {
            Button {
                _ = commit(keeping: Set(group.assetIDs))
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canKeepAll)
            .opacity(canKeepAll ? 1 : 0.45)
            .accessibilityLabel(String(localized: "全部保留"))

            Button {
                _ = commit(keeping: [], allowEmptyKeep: true)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canDeleteAll)
            .opacity(canDeleteAll ? 1 : 0.45)
            .accessibilityLabel(String(localized: "全部删除"))
            .accessibilityHint(String(localized: "本组照片会加入待删清单，确认后才从图库删除。"))

            Button {
                if selectedIDs.isEmpty {
                    keeping.formUnion(SuggestionReviewQueue.keepersToSelect(
                        in: group, visibleAssetIDs: currentAssets.map(\.localIdentifier)))
                    haptic()
                } else {
                    _ = commit(keeping: selectedIDs)
                }
            } label: {
                Text(selectedIDs.isEmpty
                     ? String(localized: "帮我选照片")
                     : String(localized: "保留 \(selectedIDs.count) 张，其余 \(currentAssets.count - selectedIDs.count) 张加入待删"))
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canActivate)
            .opacity(canActivate ? 1 : 0.45)
            .accessibilityHint(String(localized: selectedIDs.isEmpty
                ? "先帮你选中建议保留的照片；没有建议时选第一张。不会提交决定。"
                : "其余照片会进入清单，确认后才从图库删除。"))
        }
        .padding(5)
        .zeyingGlass(in: Capsule())
    }

    private func comparisonActions(for group: CleanupSuggestion, inSideBar: Bool) -> some View {
        VStack(spacing: 8) {
            (inSideBar || dynamicTypeSize.isAccessibilitySize
             ? AnyLayout(VStackLayout(spacing: 8))
             : AnyLayout(HStackLayout(spacing: 8))) {
                Button {
                    _ = commit(keeping: Set(group.assetIDs))
                } label: {
                    Label(String(localized: "全部保留"), systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemBackground).opacity(0.82), in: Capsule())
                .disabled(!canKeepAll)

                Button {
                    _ = commit(keeping: [], allowEmptyKeep: true)
                } label: {
                    Label(String(localized: "全部删除"), systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemBackground).opacity(0.82), in: Capsule())
                .disabled(!canKeepNone || !selectedIDs.isEmpty)
                .accessibilityHint(String(localized: "本组照片会加入待删清单，确认后才从图库删除。"))
            }

            Button {
                if selectedIDs.isEmpty {
                    keeping.formUnion(SuggestionReviewQueue.keepersToSelect(
                        in: group, visibleAssetIDs: currentAssets.map(\.localIdentifier)))
                    haptic()
                } else {
                    _ = commit(keeping: selectedIDs)
                }
            } label: {
                Text(selectedIDs.isEmpty
                     ? String(localized: "帮我选照片")
                     : String(localized: "保留 \(selectedIDs.count) 张，其余 \(currentAssets.count - selectedIDs.count) 张加入待删"))
                    .font(.headline)
                    .foregroundStyle(canCommit || canChooseKeepers ? Color(uiColor: .systemBackground) : Color.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(.primary)
            .disabled(selectedIDs.isEmpty ? !canChooseKeepers : !canCommit)
            .accessibilityHint(String(localized: selectedIDs.isEmpty
                ? "先帮你选中建议保留的照片；没有建议时选第一张。不会提交决定。"
                : "其余照片会进入清单，确认后才从图库删除。"))
        }
        .padding(.horizontal, inSideBar ? 12 : 20)
        .padding(.top, 12)
        .padding(.bottom, reviewInNarrowPane && verticalSizeClass == .compact ? 0 : 12)
    }

    private var comparisonColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        if usesExpandedComparisonLayout {
            return [GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 12, alignment: .top)]
        }
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 210, maximum: 350), spacing: 12, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)
    }

    private var completedContent: some View {
        Group {
            if usesExpandedCompletionLayout {
                ZeyingFoldAwareSplit {
                    completedSummary
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, reviewInNarrowPane ? 10 : 24)
                } trailing: {
                    GeometryReader { proxy in
                        ScrollView {
                            completedActions
                                .frame(maxWidth: 340)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: proxy.size.height, alignment: .center)
                        }
                        .scrollIndicators(.hidden)
                    }
                    .padding(.horizontal, reviewInNarrowPane ? 10 : 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 18) {
                    Spacer()
                    completedSummary
                    completedActions
                        .frame(maxWidth: 300)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            }
        }
    }

    private var completedSummary: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.green)

            VStack(spacing: 7) {
                Text(String(localized: "本轮建议已审核"))
                    .font(.title2.weight(.semibold))

                if pendingConfirmationCount > 0 {
                    Text(String(localized: "还有 \(pendingConfirmationCount) 项待确认操作，可到清单确认。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    private var completedActions: some View {
        VStack(spacing: 12) {
                if pendingConfirmationCount > 0 {
                    Button {
                        if let openSummaryTab { openSummaryTab() } else { dismiss() }
                    } label: {
                        completedActionLabel(String(localized: "去清单确认"), symbol: "checklist")
                    }
                    .buttonStyle(ZeyingGlassButtonStyle())
                }

                Button {
                    dismiss()
                } label: {
                    completedActionLabel(String(localized: "返回建议"), symbol: "arrow.uturn.backward")
                }
                .buttonStyle(ZeyingGlassButtonStyle())
        }
    }

    private func completedActionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: 28)
    }

    @ToolbarContentBuilder
    private var comparisonToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !reviewInNarrowPane, !undoEntries.isEmpty {
                Button(undoTitle, systemImage: "arrow.uturn.backward") { undo() }
                    .disabled(!canUndo)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if group != nil && !reviewInNarrowPane {
                Button(String(localized: "跳过本组"), systemImage: "forward.end") { skip() }
                    .labelStyle(.iconOnly)
            }
        }
    }

    private func photoCell(_ asset: PHAsset, group: CleanupSuggestion) -> some View {
        let id = asset.localIdentifier
        let selected = selectedIDs.contains(id)
        let protected = protectedIDs.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            AssetImageView(asset: asset, library: library, contentMode: .fit,
                           targetSize: CGSize(width: 1_500, height: 1_500), requiresFullQuality: true,
                           unavailablePreviewHint: String(localized: "点按查看大图。若仍无法显示，请先跳过本组。"))
                .frame(maxWidth: .infinity)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 240 : usesExpandedComparisonLayout ? 200 : 170)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { gallery = SuggestionGallerySelection(id: id) }
                .accessibilityLabel(String(localized: "放大查看照片 \(asset.creationDate?.zeyingDetailedDate ?? "")"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { gallery = SuggestionGallerySelection(id: id) }

            Button {
                if selected { keeping.remove(id) } else { keeping.insert(id) }
                haptic()
            } label: {
                Label {
                    Text(String(localized: protected ? "已受保留保护" : selected ? "保留" : "选择保留"))
                        .font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: protected ? "lock.circle.fill" : selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(protected)
            .accessibilityValue(String(localized: selected ? "已选中" : "未选中"))

            if id == group.recommendedKeepID && group.visibleSuggestedKeeperIDs.contains(id) {
                Label(String(localized: "建议保留"), systemImage: "wand.and.stars")
                    .font(.caption.weight(.semibold))
            } else if let portraitReason = group.portraitReason(for: id) {
                Label(portraitReason, systemImage: "person.crop.circle")
                    .font(.caption.weight(.semibold))
            } else if group.visibleSuggestedKeeperIDs.contains(id) {
                Label(String(localized: "建议保留"), systemImage: "wand.and.stars")
                    .font(.caption.weight(.semibold))
            }
            SuggestionFileSizeLabel(asset: asset, sizes: sizes)
        }
    }

    private func prefetchNeighboringGroups() async {
        for neighbor in [index + 1, index - 1] where groups.indices.contains(neighbor) {
            for identifier in groups[neighbor].assetIDs.prefix(neighbor > index ? 4 : 2) {
                guard !Task.isCancelled else { return }
                if let asset = library.asset(with: identifier) {
                    _ = await library.prepareReviewPreview(for: asset)
                }
            }
        }
    }

    @discardableResult
    private func commit(keeping selected: Set<String>, allowEmptyKeep: Bool = false) -> Bool {
        guard !allowEmptyKeep || selectedIDs.isEmpty else { return false }
        guard let group, suggestions.isCurrent(group, library: library), currentAssets.count == group.assetIDs.count,
              !group.assetIDs.contains(where: { reviews.decision(for: $0) == .delete || reviews.decision(for: $0) == .later }) else {
            showingError = true
            return false
        }
        let keptIDs = selected.union(protectedIDs)
        let alreadyKeptAll = !allowEmptyKeep && keptIDs == Set(group.assetIDs) &&
            group.assetIDs.allSatisfy { reviews.decision(for: $0) == .keep }
        let recorded = allowEmptyKeep
            ? protectedIDs.isEmpty && reviews.stageGroupForDeletion(group.assetIDs)
            : reviews.decideGroup(group.assetIDs, keeping: keptIDs)
        guard recorded || alreadyKeptAll else { showingError = true; return false }
        let keptCount = allowEmptyKeep ? 0 : keptIDs.count
        if recorded, let token = reviews.latestUndoToken { undoEntries.append((index, token, true, keptCount)) }
        groupDecisionHaptic()
        suggestions.recordReview(of: group, kept: keptCount)
        advance()
        return true
    }

    private func skip() {
        if let group { suggestions.skip(group) }
        haptic()
        advance()
    }

    private func advance() {
        if let group { groupDrafts.removeValue(forKey: group.id) }
        index += 1
        keeping = self.group.map { initialSelection(for: $0) } ?? []
        startedUndoToken = reviews.latestUndoToken
        rememberSession()
        selection?.wrappedValue = group?.id
    }

    private func browseGroup(_ direction: Int) {
        guard direction == -1 || direction == 1 else { return }
        var target = index + direction
        while groups.indices.contains(target) {
            let candidate = groups[target]
            let hasPendingDeletion = candidate.assetIDs.contains {
                let decision = reviews.decision(for: $0)
                return decision == .delete || decision == .later
            }
            if !suggestions.skippedIDs.contains(candidate.id),
               !suggestions.isReviewedGroup(candidate, reviews: reviews), !hasPendingDeletion,
               suggestions.isCurrent(candidate, library: library) {
                gallery = nil
                if let group { groupDrafts[group.id] = keeping }
                withAnimation(.easeInOut(duration: 0.18)) {
                    index = target
                    keeping = initialSelection(for: candidate)
                }
                startedUndoToken = reviews.latestUndoToken
                rememberSession()
                selection?.wrappedValue = group?.id
                haptic()
                return
            }
            target += direction
        }
    }

    private func finishScreenshots() {
        if let token = reviews.latestUndoToken, token != startedUndoToken {
            undoEntries.append((index, token, false, nil))
        }
        advance()
    }

    private func undo() {
        guard let entry = undoEntries.last, reviews.undo(matching: entry.token) else { return }
        if let kept = entry.learnedKept, groups.indices.contains(entry.index) {
            suggestions.undoRecordedReview(of: groups[entry.index], kept: kept)
        }
        index = entry.index
        undoEntries.removeLast()
        keeping = group.map { initialSelection(for: $0) } ?? []
        startedUndoToken = reviews.latestUndoToken
        rememberSession()
        selection?.wrappedValue = group?.id
        haptic()
    }

    private func rememberSession() { suggestions.rememberSession(groups, index: index) }
    private func publishPaneUndoState() {
        guard reviewInNarrowPane else { return }
        paneUndoState?.wrappedValue = SuggestionPaneUndoState(
            isVisible: !undoEntries.isEmpty, isEnabled: canUndo, title: undoTitle)
    }
    private func initialSelection(for group: CleanupSuggestion) -> Set<String> {
        groupDrafts[group.id] ?? Set(group.assetIDs.filter { reviews.decision(for: $0) == .keep })
    }
    private func haptic() { if settings.hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() } }

    private func groupDecisionHaptic() {
        if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }

}

private struct SuggestionGallerySelection: Identifiable { let id: String }

private extension CleanupSuggestion {
    func recommendationDetail(for assetID: String) -> String? {
        if let portraitReason = portraitReason(for: assetID) { return portraitReason }
        guard recommendedKeepID == assetID, let recommendationBasis else { return nil }
        switch recommendationBasis {
        case .protected:
            return String(localized: "你已收藏或保留这张，建议继续留着；其他版本也可以一起留。")
        case .identicalResources:
            return String(localized: "原始文件内容完全相同，留这一张即可。")
        case .resolution, .visionAesthetics:
            return nil
        }
    }
}

private struct SuggestionFileSizeLabel: View {
    let asset: PHAsset
    let sizes: AssetSizeService
    var foregroundColor: Color = .secondary
    var labelFont: Font = .caption.monospacedDigit()
    @State private var resolvedSize: (assetID: String, bytes: Int64?)?

    var body: some View {
        Group {
            if let resolvedSize, resolvedSize.assetID == asset.localIdentifier {
                if let bytes = resolvedSize.bytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                } else {
                    Text(String(localized: "大小暂不可用"))
                }
            } else {
                Text("0 MB").hidden()
            }
        }
        .font(labelFont)
        .foregroundStyle(foregroundColor)
        .task(id: asset.localIdentifier, priority: .utility) {
            let assetID = asset.localIdentifier
            resolvedSize = nil
            if let bytes = sizes.knownSize(for: asset) {
                resolvedSize = (assetID, bytes)
            } else {
                let bytes = await sizes.automaticLocalSize(for: asset)
                guard !Task.isCancelled else { return }
                resolvedSize = (assetID, bytes)
            }
        }
    }
}

private struct SuggestionPhotoGallery: View {
    let group: CleanupSuggestion
    let assetIDs: [String]
    let library: PhotoLibraryService
    let sizes: AssetSizeService
    @Binding var keeping: Set<String>
    let protectedIDs: Set<String>
    let hasNextGroup: Bool
    let canAdvance: Bool
    let canKeepAll: Bool
    let canKeepNone: Bool
    let expandedFold: Bool
    let foldedPortraitHeaderInset: CGFloat
    let onAdvance: (GalleryGroupDecision) -> GalleryAdvanceResult
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedID: String
    @State private var showingInfo = false
    @State private var reachedLastPhotoByNextAt: Date?
    @State private var ignoredRapidFinalTap = false

    private var recommendationReason: String? {
        if let portraitReason = group.portraitReason(for: selectedID) { return portraitReason }
        guard group.visibleSuggestedKeeperIDs.contains(selectedID) else { return nil }
        if selectedID == group.recommendedKeepID {
            return group.recommendationDetail(for: selectedID)
        }
        return String(localized: "同一场景的不同瞬间，可以一起保留。")
    }

    private var usesExpandedGalleryLayout: Bool {
        (expandedFold || horizontalSizeClass == .regular) && !dynamicTypeSize.isAccessibilitySize
    }

    private var usesFoldedGalleryToolbar: Bool {
        foldedPortraitHeaderInset > 0 && !expandedFold
    }

    private var galleryLayout: AnyLayout {
        usesExpandedGalleryLayout
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
    }

    init(group: CleanupSuggestion, assetIDs: [String], initialID: String, library: PhotoLibraryService,
         sizes: AssetSizeService, keeping: Binding<Set<String>>, protectedIDs: Set<String>,
         hasNextGroup: Bool, canAdvance: Bool, canKeepAll: Bool, canKeepNone: Bool,
         expandedFold: Bool, foldedPortraitHeaderInset: CGFloat,
         onAdvance: @escaping (GalleryGroupDecision) -> GalleryAdvanceResult) {
        self.group = group
        self.assetIDs = assetIDs
        self.library = library
        self.sizes = sizes
        _keeping = keeping
        self.protectedIDs = protectedIDs
        self.hasNextGroup = hasNextGroup
        self.canAdvance = canAdvance
        self.canKeepAll = canKeepAll
        self.canKeepNone = canKeepNone
        self.expandedFold = expandedFold
        self.foldedPortraitHeaderInset = foldedPortraitHeaderInset
        self.onAdvance = onAdvance
        _selectedID = State(initialValue: initialID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if expandedFold && usesExpandedGalleryLayout {
                    ZeyingFoldAwareSplit {
                        expandedPhotoPane
                    } trailing: {
                        gallerySidePanel
                            .frame(maxWidth: .infinity)
                    }
                } else if usesFoldedGalleryToolbar {
                    GeometryReader { geometry in
                        // Give the zoomable pager a stable area between the
                        // camera-side toolbar and the decision controls. Without
                        // an explicit height, TabView sizes this area differently
                        // for portrait and landscape photos.
                        let topClearance = min(56, geometry.size.height * 0.08)
                        let bottomClearance = min(210, geometry.size.height * 0.30)
                        let photoHeight = max(1, geometry.size.height - topClearance - bottomClearance)

                        ZStack(alignment: .bottom) {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: topClearance)
                                photoPager
                                    .padding(.leading, 76)
                                    .frame(height: photoHeight)
                                    .overlay(alignment: .bottom) {
                                        SuggestionGalleryPageControl(
                                            pageCount: assetIDs.count,
                                            currentPage: assetIDs.firstIndex(of: selectedID) ?? 0
                                        ) { page in
                                            guard assetIDs.indices.contains(page) else { return }
                                            selectedID = assetIDs[page]
                                        }
                                        .frame(height: 20)
                                        .offset(y: 22)
                                    }
                                Color.clear.frame(height: bottomClearance)
                            }
                            gallerySidePanel
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    galleryLayout {
                        photoPager
                        gallerySidePanel
                    }
                }
            }
            .background(.black)
            .onChange(of: assetIDs) { _, ids in
                reachedLastPhotoByNextAt = nil
                ignoredRapidFinalTap = false
                if !ids.contains(selectedID), let first = ids.first { selectedID = first }
            }
            .onChange(of: selectedID) { _, id in
                if id != assetIDs.last {
                    reachedLastPhotoByNextAt = nil
                    ignoredRapidFinalTap = false
                }
            }
            .navigationTitle(expandedFold || usesFoldedGalleryToolbar ? "" :
                             String(localized: "\((assetIDs.firstIndex(of: selectedID) ?? 0) + 1) / \(assetIDs.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(expandedFold || usesFoldedGalleryToolbar)
            .toolbar(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if expandedFold || usesFoldedGalleryToolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel(String(localized: "返回建议审核"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(library.asset(with: selectedID)?.mediaType.zeyingDetailsTitle ?? String(localized: "照片信息"),
                               systemImage: "info.circle") { showingInfo = true }
                    }
                    if #available(iOS 27.0, *) {
                        ToolbarItem(placement: .topBarPinnedTrailing) {
                            Button(String(localized: "完成"), systemImage: "checkmark") { dismiss() }
                                .labelStyle(.iconOnly)
                        }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "完成"), systemImage: "checkmark") { dismiss() }
                                .labelStyle(.iconOnly)
                        }
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(String(localized: "返回建议审核"))

                        Button(library.asset(with: selectedID)?.mediaType.zeyingDetailsTitle ?? String(localized: "照片信息"),
                               systemImage: "info.circle") { showingInfo = true }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "完成")) { dismiss() }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if usesFoldedGalleryToolbar {
                    Text("\((assetIDs.firstIndex(of: selectedID) ?? 0) + 1) / \(assetIDs.count)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 20)
                        .padding(.top, 4 + foldedPortraitHeaderInset)
                        .allowsHitTesting(false)
                }
            }
            .sheet(isPresented: $showingInfo) {
                if let asset = library.asset(with: selectedID) {
                    NavigationStack {
                        ScrollView { AssetInfoView(asset: asset, sizes: sizes).padding(20) }
                            .navigationTitle(asset.mediaType.zeyingDetailsTitle)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { showingInfo = false } } }
                    }
                }
            }
        }
    }

    private var expandedPhotoPane: some View {
        GeometryReader { geometry in
            let asset = library.asset(with: selectedID)
            let aspectRatio = asset.map { CGFloat($0.pixelWidth) / CGFloat(max($0.pixelHeight, 1)) } ?? 1
            let maxPhotoWidth = geometry.size.width * 0.82
            let maxPhotoHeight = max(1, geometry.size.height - 90)
            let photoWidth = min(maxPhotoWidth, maxPhotoHeight * aspectRatio)
            let photoHeight = photoWidth / aspectRatio

            VStack(spacing: 8) {
                Text("\((assetIDs.firstIndex(of: selectedID) ?? 0) + 1) / \(assetIDs.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                photoPager
                    .frame(width: photoWidth, height: photoHeight)
                    .overlay(alignment: .bottom) {
                        SuggestionGalleryPageControl(
                            pageCount: assetIDs.count,
                            currentPage: assetIDs.firstIndex(of: selectedID) ?? 0
                        ) { page in
                            guard assetIDs.indices.contains(page) else { return }
                            selectedID = assetIDs[page]
                        }
                        .frame(height: 24)
                        .offset(y: 28)
                    }
            }
            .padding(.bottom, 33)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
    }

    private var photoPager: some View {
        TabView(selection: $selectedID) {
            ForEach(assetIDs, id: \.self) { id in
                if let asset = library.asset(with: id) {
                    SuggestionZoomPhoto(
                        asset: asset,
                        library: library,
                        allowNetwork: settings.iCloudAutoDownloadEnabled && selectedID == id
                    ).tag(id)
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: usesFoldedGalleryToolbar ||
            (expandedFold && usesExpandedGalleryLayout) ? .never : .automatic))
        .background(.black)
    }

    private var gallerySidePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if usesExpandedGalleryLayout {
                if let recommendationReason {
                    recommendationCallout(recommendationReason)
                        .frame(height: 120)
                }
                Spacer(minLength: 8)
                HStack(alignment: .center, spacing: 12) {
                    if let asset = library.asset(with: selectedID) {
                        SuggestionFileSizeLabel(asset: asset, sizes: sizes,
                                                foregroundColor: .white,
                                                labelFont: .subheadline.monospacedDigit())
                    }
                    keepPhotoButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                    if let recommendationReason {
                        recommendationCallout(recommendationReason)
                    }
                }
                .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 100)
                HStack(spacing: 12) {
                    if let asset = library.asset(with: selectedID) {
                        SuggestionFileSizeLabel(asset: asset, sizes: sizes,
                                                foregroundColor: .white,
                                                labelFont: .subheadline.monospacedDigit())
                    }
                    Spacer(minLength: 0)
                    keepPhotoButton
                }
            }
            galleryActions
                .frame(maxWidth: .infinity,
                       minHeight: usesExpandedGalleryLayout ? nil : 104,
                       alignment: .bottom)
        }
        .padding(.horizontal, 20)
        .padding(.top, usesExpandedGalleryLayout ? 40 : 10)
        .padding(.bottom, usesExpandedGalleryLayout ? 30 : 10)
        .background(usesFoldedGalleryToolbar ? Color.clear : Color.black)
        .frame(minWidth: usesExpandedGalleryLayout ? 230 : nil,
               idealWidth: usesExpandedGalleryLayout ? 280 : nil,
               maxWidth: usesExpandedGalleryLayout ? 320 : .infinity)
        .frame(maxHeight: usesExpandedGalleryLayout ? .infinity : nil,
               alignment: usesExpandedGalleryLayout ? .top : .bottom)
    }

    private var keepPhotoButton: some View {
        Button {
            if keeping.contains(selectedID) { keeping.remove(selectedID) }
            else { keeping.insert(selectedID) }
            if settings.hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
        } label: {
            Label(protectedIDs.contains(selectedID) ? String(localized: "已保留") :
                  keeping.contains(selectedID) ? String(localized: "取消保留") : String(localized: "保留这张"),
                  systemImage: protectedIDs.contains(selectedID) ? "lock.fill" :
                    keeping.contains(selectedID) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(.black)
                .frame(minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white)
        .frame(minHeight: 44)
        .disabled(protectedIDs.contains(selectedID))
    }

    private func recommendationCallout(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "建议保留"), systemImage: "wand.and.stars")
                .font(.subheadline.weight(.semibold))
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: .infinity,
               maxHeight: usesExpandedGalleryLayout ? .infinity : nil,
               alignment: .topLeading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private var galleryActions: some View {
        VStack(spacing: 8) {
            if let position = assetIDs.firstIndex(of: selectedID) {
                if position > 0 {
                    Button {
                        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) {
                            selectedID = assetIDs[position - 1]
                        }
                        if settings.hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
                    } label: {
                        Label(String(localized: "上一张照片"), systemImage: "arrow.left")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.white)
                    .frame(minHeight: 44)
                }

                if position < assetIDs.count - 1 {
                    Button {
                        if position + 1 == assetIDs.count - 1 {
                            reachedLastPhotoByNextAt = .now
                            ignoredRapidFinalTap = false
                        }
                        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.2)) {
                            selectedID = assetIDs[position + 1]
                        }
                        if settings.hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
                    } label: {
                        HStack(spacing: 8) {
                            Text(String(localized: "下一张照片"))
                            Image(systemName: "arrow.right")
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Color(red: 0.20, green: 0.54, blue: 0.84))
                    .frame(minHeight: 44)
                } else {
                    let selectedCount = keeping.union(protectedIDs).intersection(Set(assetIDs)).count
                    if selectedCount > 0 && selectedCount < assetIDs.count {
                        Button {
                            advance(.selected)
                        } label: {
                            HStack(spacing: 8) {
                                Text(String(localized: "保留已选照片并继续"))
                                Image(systemName: "arrow.right")
                            }
                            .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(Color(red: 0.20, green: 0.54, blue: 0.84))
                        .disabled(!canAdvance)
                        .frame(minHeight: 44)
                    }
                    HStack(spacing: 8) {
                        groupAction(String(localized: "全部保留"), choice: .all, enabled: canKeepAll)
                        groupAction(String(localized: "全部删除"), choice: .none,
                                    enabled: canKeepNone && keeping.intersection(Set(assetIDs)).isEmpty)
                    }
                }
            }
        }
    }

    private func groupAction(_ title: String, choice: GalleryGroupDecision, enabled: Bool) -> some View {
        Button {
            advance(choice)
        } label: {
            VStack(spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(hasNextGroup ? String(localized: "下一组 →") : String(localized: "完成 →"))
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(!enabled)
        .accessibilityHint(choice == .none
            ? String(localized: "本组照片会加入待删清单，确认后才从图库删除。")
            : String(localized: "本组照片会全部保留"))
    }

    private func advance(_ choice: GalleryGroupDecision) {
        if let reachedAt = reachedLastPhotoByNextAt,
           Date.now.timeIntervalSince(reachedAt) < 0.8,
           !ignoredRapidFinalTap {
            ignoredRapidFinalTap = true
            return
        }
        reachedLastPhotoByNextAt = nil
        switch onAdvance(choice) {
        case .failed: break
        case .dismiss: dismiss()
        case .next(let identifier): selectedID = identifier
        }
    }
}

private enum GalleryGroupDecision: Equatable { case selected, all, none }
private enum GalleryAdvanceResult { case failed, next(String), dismiss }

private struct SuggestionGalleryPageControl: UIViewRepresentable {
    let pageCount: Int
    let currentPage: Int
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPageChange: onPageChange) }

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.hidesForSinglePage = true
        control.currentPageIndicatorTintColor = .white
        control.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.45)
        control.backgroundStyle = .minimal
        control.addTarget(context.coordinator, action: #selector(Coordinator.pageChanged(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.onPageChange = onPageChange
        control.numberOfPages = pageCount
        control.currentPage = currentPage
    }

    final class Coordinator: NSObject {
        var onPageChange: (Int) -> Void

        init(onPageChange: @escaping (Int) -> Void) { self.onPageChange = onPageChange }

        @objc func pageChanged(_ control: UIPageControl) {
            onPageChange(control.currentPage)
        }
    }
}

private struct SuggestionZoomPhoto: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    let allowNetwork: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var retry = 0
    @State private var isCloudPhoto = false

    var body: some View {
        ZStack {
            Color.black
            if let image { NativeSuggestionZoomView(image: image) }
            else if loaded {
                ContentUnavailableView {
                    Label(String(localized: "照片暂时无法加载"), systemImage: "photo")
                } description: {
                    Text(allowNetwork
                         ? String(localized: "暂时无法加载云端内容，请检查网络后重试。本地预览仍可用于整理。")
                         : String(localized: "低清预览暂时无法加载；原片不会自动下载，可关闭后继续核对其他项目。"))
                } actions: {
                    if isCloudPhoto {
                        Button(String(localized: "重试 iCloud 预览")) { retry += 1 }
                    }
                }
                .foregroundStyle(.white)
            } else { ProgressView().tint(.white) }
        }
        .accessibilityIdentifier("suggestionPhotoViewport")
        .task(id: "\(asset.localIdentifier)-\(library.revision)-\(retry)-\(allowNetwork)") {
            loaded = false
            image = library.cachedReviewPreview(for: asset) ?? library.cachedQuickPreview(for: asset)
            if image == nil { image = await library.quickPreview(for: asset) }
            guard !Task.isCancelled else { return }
            if image == nil { image = await library.cloudThumbnail(for: asset) }
            guard !Task.isCancelled else { return }
            if image != nil { loaded = true }
            let requestedImage = await library.requestImage(
                for: asset,
                targetSize: CGSize(width: 2_400, height: 2_400),
                allowNetwork: allowNetwork,
                deliveryMode: .highQualityFormat
            )
            guard !Task.isCancelled else { return }
            isCloudPhoto = library.isKnownCloudAsset(asset)
            if let requestedImage {
                image = requestedImage
                library.cacheReviewPreview(requestedImage, for: asset)
            }
            if !Task.isCancelled { loaded = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, image == nil { retry += 1 }
        }
    }
}

/// UIKit supplies zooming, panning, momentum, and gesture arbitration.
private struct NativeSuggestionZoomView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = SuggestionZoomScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = context.coordinator
        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "照片预览")
        imageView.accessibilityValue = String(localized: "缩放 \(100)%")
        imageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "放大"), target: context.coordinator, selector: #selector(Coordinator.zoomIn)),
            UIAccessibilityCustomAction(name: String(localized: "缩小"), target: context.coordinator, selector: #selector(Coordinator.zoomOut)),
            UIAccessibilityCustomAction(name: String(localized: "恢复原始大小"), target: context.coordinator, selector: #selector(Coordinator.resetZoom))
        ]
        scroll.addSubview(imageView)
        scroll.zoomImageView = imageView
        context.coordinator.scrollView = scroll
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        if scroll.zoomScale == 1 {
            context.coordinator.imageView.frame = scroll.bounds
            scroll.contentSize = scroll.bounds.size
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            imageView.accessibilityValue = String(localized: "缩放 \(Int(scrollView.zoomScale * 100))%")
        }
        @objc func zoomIn() -> Bool { setZoom((scrollView?.zoomScale ?? 1) + 1) }
        @objc func zoomOut() -> Bool { setZoom((scrollView?.zoomScale ?? 1) - 1) }
        @objc func resetZoom() -> Bool { setZoom(1) }
        private func setZoom(_ value: CGFloat) -> Bool {
            guard let scroll = scrollView else { return false }
            scroll.setZoomScale(min(max(value, 1), 4), animated: !UIAccessibility.isReduceMotionEnabled)
            return true
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                            animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }
}

private final class SuggestionZoomScrollView: UIScrollView {
    weak var zoomImageView: UIImageView?
    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale == 1 else { return }
        zoomImageView?.frame = CGRect(origin: .zero, size: bounds.size)
        if contentSize != bounds.size { contentSize = bounds.size }
    }
}
