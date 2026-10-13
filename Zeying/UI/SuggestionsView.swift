import Photos
import SwiftUI
import UIKit

struct SuggestionsView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore
    let showsBackToHome: Bool
    let isFullScreenReview: Bool
    let onBackToHome: () -> Void

    @Environment(PhotoSuggestionService.self) private var suggestions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.zeyingFoldedPortraitHeaderInset) private var foldedPortraitHeaderInset
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter: SuggestionKind?
    @State private var isVisible = false
    @State private var shuffledGroupIDs: [String] = []
    @State private var showingSuggestionInfo = false
    @State private var selectedGroupID: String?
    @State private var paneUndoState = SuggestionPaneUndoState.hidden
    @State private var paneUndoRequest = 0
    @State private var paneSkipRequest = 0
    @AppStorage("com.mars.zeying.suggestionListOrder.v1") private var listOrderRaw = SuggestionListOrder.recommended.rawValue

    private var listOrder: SuggestionListOrder {
        SuggestionListOrder(rawValue: listOrderRaw) ?? .recommended
    }

    private var usesFoldAwareSplit: Bool {
        if #available(iOS 27.1, *), horizontalSizeClass == .regular { true }
        else { false }
    }

    private var usesNativeExpandedToolbar: Bool {
        UIDevice.current.userInterfaceIdiom == .phone &&
            (horizontalSizeClass == .regular || verticalSizeClass == .compact)
    }

    private var usesFoldedPortraitToolbar: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && foldedPortraitHeaderInset > 0
    }

    private var groups: [CleanupSuggestion] {
        let source = suggestions.availableGroups(library: library, reviews: reviews)
        let ordered: [CleanupSuggestion]
        switch listOrder {
        case .recommended:
            ordered = SuggestionRecommendedOrdering.sorted(source, learning: suggestions.orderLearning)
        case .oldestFirst, .newestFirst:
            ordered = source.enumerated().sorted { left, right in
                if left.element.newestDate != right.element.newestDate {
                    guard let leftDate = left.element.newestDate else { return false }
                    guard let rightDate = right.element.newestDate else { return true }
                    return listOrder == .oldestFirst ? leftDate < rightDate : leftDate > rightDate
                }
                return left.offset < right.offset
            }.map(\.element)
        }
        guard !shuffledGroupIDs.isEmpty else { return ordered }
        let positions = Dictionary(uniqueKeysWithValues: shuffledGroupIDs.enumerated().map { ($0.element, $0.offset) })
        return ordered.enumerated().sorted { left, right in
            let first = positions[left.element.id] ?? Int.max
            let second = positions[right.element.id] ?? Int.max
            return first == second ? left.offset < right.offset : first < second
        }.map(\.element)
    }
    var body: some View {
        let allGroups = groups
        let filteredGroups = allGroups.filter { filter == nil || $0.kind == filter }
        let expanded = foldedPortraitHeaderInset == 0 &&
            (horizontalSizeClass == .regular || verticalSizeClass == .compact) &&
            !dynamicTypeSize.isAccessibilitySize
        Group {
            if expanded {
                ZeyingFoldAwareSplit(divisionFill: Color(uiColor: .systemGroupedBackground)) {
                    VStack(alignment: .leading, spacing: 0) {
                        ZeyingRootPageTitle(
                            title: String(localized: "清理建议"),
                            matchesHomeExpandedPosition: true
                        )
                        suggestionList(allGroups: allGroups, filteredGroups: filteredGroups, expanded: true)
                    }
                    .padding(.top, usesNativeExpandedToolbar ? -16 : 0)
                    .frame(minWidth: 310, idealWidth: usesFoldAwareSplit ? nil : 380,
                           maxWidth: usesFoldAwareSplit ? .infinity : 460,
                           maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(uiColor: .systemGroupedBackground)
                        .ignoresSafeArea(.container, edges: [.top, .leading]))
                } trailing: {
                    Group {
                        if let selected = filteredGroups.first(where: { $0.id == selectedGroupID }) ?? filteredGroups.first {
                            session(filteredGroups, startingAt: selected, selection: $selectedGroupID,
                                    paneUndoState: $paneUndoState, paneUndoRequest: paneUndoRequest,
                                    paneSkipRequest: paneSkipRequest)
                                .environment(\.horizontalSizeClass, .compact)
                                .environment(\.reviewInNarrowPane, true)
                        } else {
                            emptyContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color(uiColor: .systemBackground)
                        .ignoresSafeArea(.container, edges: [.top, .trailing, .bottom]))
                    .overlay(alignment: .topTrailing) {
                        if !usesNativeExpandedToolbar {
                            floatingExpandedToolbar(allGroups: allGroups, filteredGroups: filteredGroups)
                                .padding(.trailing, 20)
                                .padding(.top, 12)
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    compactHeader(allGroups: allGroups)
                    suggestionList(allGroups: allGroups, filteredGroups: filteredGroups, expanded: false)
                }
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            }
        }
        .navigationTitle("")
        .toolbar((usesNativeExpandedToolbar && expanded) || usesFoldedPortraitToolbar
                 ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isFullScreenReview {
                    EmptyView()
                } else if usesNativeExpandedToolbar && expanded {
                    if !filteredGroups.isEmpty && paneUndoState.isVisible {
                        Button {
                            paneUndoRequest += 1
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(!paneUndoState.isEnabled)
                        .accessibilityLabel(paneUndoState.title)
                    }
                    shuffleButton(allGroups: allGroups)
                    if let currentGroupID = (filteredGroups.first { $0.id == selectedGroupID } ?? filteredGroups.first)?.id {
                        NavigationLink(value: SuggestionSessionDestination(groupID: currentGroupID)) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityLabel(String(localized: "全屏审核当前建议组"))
                    }
                    suggestionOptionsMenu
                    if !filteredGroups.isEmpty {
                        Button {
                            paneSkipRequest += 1
                        } label: {
                            Image(systemName: "forward.end")
                        }
                        .accessibilityLabel(String(localized: "跳过本组"))
                    }
                } else if usesFoldedPortraitToolbar {
                    shuffleButton(allGroups: allGroups)
                    suggestionOptionsMenu
                }
            }
        }
        .navigationDestination(for: SuggestionSessionDestination.self) { destination in
            let visibleGroups = groups.filter { filter == nil || $0.kind == filter }
            session(visibleGroups, startingAt: visibleGroups.first { $0.id == destination.groupID })
        }
        .task(id: library.revision) { suggestions.startIfNeeded(library: library, reviews: reviews) }
        .onAppear { isVisible = true }
        .onChange(of: listOrderRaw) { _, _ in shuffledGroupIDs.removeAll() }
        .onChange(of: filter) { _, _ in selectedGroupID = nil }
        .onChange(of: filteredGroups.map(\.id)) { previousIDs, visibleIDs in
            if let selectedGroupID, !visibleIDs.contains(selectedGroupID) {
                let previousIndex = previousIDs.firstIndex(of: selectedGroupID) ?? 0
                self.selectedGroupID = visibleIDs.isEmpty ? nil : visibleIDs[min(previousIndex, visibleIDs.count - 1)]
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isVisible { suggestions.startIfNeeded(library: library, reviews: reviews) }
        }
        .onDisappear { isVisible = false }
        .alert(String(localized: "关于建议"), isPresented: $showingSuggestionInfo) {
            Button(String(localized: "知道了"), role: .cancel) {}
        } message: {
            Text(suggestionDetails)
        }
    }

    private func compactHeader(allGroups: [CleanupSuggestion]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if showsBackToHome {
                Button(action: onBackToHome) {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "返回首页"))
                .zeyingGlass(in: Circle())
            }

            Text(String(localized: "清理建议"))
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 44, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            if !usesFoldedPortraitToolbar {
                HStack(spacing: 8) {
                    shuffleButton(allGroups: allGroups)
                        .frame(width: 44, height: 44)
                        .zeyingGlass(in: Circle())
                    suggestionOptionsMenu
                        .frame(width: 44, height: 44)
                        .zeyingGlass(in: Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .font(.title3)
        .buttonStyle(.plain)
    }

    private func expandedToolbar(allGroups: [CleanupSuggestion],
                                 filteredGroups: [CleanupSuggestion]) -> some View {
        return HStack(spacing: 4) {
            if !filteredGroups.isEmpty && paneUndoState.isVisible {
                Button {
                    paneUndoRequest += 1
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                }
                .disabled(!paneUndoState.isEnabled)
                .accessibilityLabel(paneUndoState.title)
            }
            if showsBackToHome {
                Button(action: onBackToHome) {
                    Image(systemName: "house").frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "返回首页"))
            }
            shuffleButton(allGroups: allGroups)
                .frame(width: 44, height: 44)
            if let currentGroupID = (filteredGroups.first { $0.id == selectedGroupID } ?? filteredGroups.first)?.id {
                NavigationLink(value: SuggestionSessionDestination(groupID: currentGroupID)) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "全屏审核当前建议组"))
            }
            suggestionOptionsMenu
                .frame(width: 44, height: 44)
            if !filteredGroups.isEmpty {
                Button {
                    paneSkipRequest += 1
                } label: {
                    Image(systemName: "forward.end").frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "跳过本组"))
            }
        }
        .font(.title2)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func floatingExpandedToolbar(allGroups: [CleanupSuggestion],
                                         filteredGroups: [CleanupSuggestion]) -> some View {
        if #available(iOS 26.0, *) {
            expandedToolbar(allGroups: allGroups, filteredGroups: filteredGroups)
                .glassEffect(.clear, in: Capsule())
        } else {
            expandedToolbar(allGroups: allGroups, filteredGroups: filteredGroups)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var suggestionOptionsMenu: some View {
        Menu {
            Button(String(localized: "关于建议"), systemImage: "info.circle") {
                showingSuggestionInfo = true
            }
            if suggestions.isScanning {
                Button(String(localized: "暂停分析"), systemImage: "pause") { suggestions.pause(manually: true) }
            } else {
                Button(String(localized: "更新建议"), systemImage: "arrow.clockwise") {
                    suggestions.start(library: library, reviews: reviews)
                }
            }
            if !suggestions.skippedIDs.isEmpty {
                Button(String(localized: "恢复已跳过的建议"), systemImage: "arrow.uturn.backward") { suggestions.restoreSkipped() }
            }
            if suggestions.orderLearning.hasHistory {
                Button(String(localized: "重置建议顺序"), systemImage: "arrow.counterclockwise") {
                    suggestions.resetOrderLearning()
                }
            }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel(String(localized: "建议选项"))
    }

    private func shuffleButton(allGroups: [CleanupSuggestion]) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                if shuffledGroupIDs.isEmpty {
                    let original = allGroups.map(\.id)
                    var shuffled = original.shuffled()
                    if shuffled == original, shuffled.count >= 2 { shuffled.swapAt(0, 1) }
                    shuffledGroupIDs = shuffled
                } else {
                    shuffledGroupIDs.removeAll()
                }
            }
        } label: {
            Image(systemName: shuffledGroupIDs.isEmpty ? "shuffle" : "arrow.up.arrow.down")
        }
        .disabled(shuffledGroupIDs.isEmpty && allGroups.count < 2)
        .accessibilityLabel(String(localized: shuffledGroupIDs.isEmpty ? "随机排列建议" : "恢复推荐顺序"))
    }

    private func suggestionList(allGroups: [CleanupSuggestion], filteredGroups: [CleanupSuggestion],
                                expanded: Bool) -> some View {
        let firstGroupID = filteredGroups.first?.id
        let selectedRowID = selectedGroupID ?? firstGroupID
        let resumedGroups: [CleanupSuggestion] = {
            guard shuffledGroupIDs.isEmpty, listOrder == .recommended else { return [] }
            let lookup = Dictionary(uniqueKeysWithValues: filteredGroups.map { ($0.id, $0) })
            return suggestions.resumeGroupIDs.compactMap { lookup[$0] }
        }()
        let visiblePhotoCount = Set(allGroups.flatMap {
            suggestions.visibleAssetIDs(in: $0, library: library, reviews: reviews)
        }).count
        let scanComplete = suggestions.displayedProgress.percentage(complete: suggestions.hasScanned) == 100
        let showsScanStatus = !scanComplete && (suggestions.isScanning || suggestions.isManuallyPaused ||
            suggestions.isEnergyPaused || !suggestions.hasScanned)
        return List {
            Section {
                VStack(alignment: .leading, spacing: showsScanStatus ? 4 : 0) {
                    Text(String(localized: "\(allGroups.count) 组建议 · \(visiblePhotoCount) 张照片"))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showsScanStatus {
                        SuggestionScanStatusView(library: library, reviews: reviews, isVisible: isVisible)
                    }
                }
                .padding(.vertical, showsScanStatus ? 4 : 2)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                filterPicker
                    .padding(.top, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            Section {
                if filteredGroups.isEmpty {
                    emptyContent
                        .listRowBackground(Color.clear)
                } else {
                    // SwiftUI otherwise compares the entire array of large group
                    // values while diffing the list, including when switching tabs.
                    ForEach(filteredGroups.map(\.id), id: \.self) { groupID in
                        if let group = suggestions.groups.first(where: { $0.id == groupID }) {
                            Group {
                                if expanded {
                                    Button { selectedGroupID = groupID } label: {
                                        SuggestionRow(group: group, library: library, reviews: reviews)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(selectedRowID == groupID
                                        ? Color.accentColor.opacity(0.12) : Color.clear)
                                    .accessibilityAddTraits(selectedRowID == groupID ? .isSelected : [])
                                } else {
                                    NavigationLink(value: SuggestionSessionDestination(groupID: groupID)) {
                                        SuggestionRow(group: group, library: library, reviews: reviews)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(String(localized: "跳过"), systemImage: "forward.end") { suggestions.skip(group) }
                                    .tint(.secondary)
                            }
                        }
                    }
                }
            } header: {
                if !filteredGroups.isEmpty { sortingMenu }
            }

            if let error = suggestions.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(0)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !expanded && !filteredGroups.isEmpty {
                NavigationLink(value: SuggestionSessionDestination(
                    groupID: resumedGroups.first?.id ?? firstGroupID ?? "")) {
                    Label(String(localized: resumedGroups.isEmpty ? "开始整理" : "继续整理"), systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.primary)
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    private var filterPicker: some View {
        let categories: [SuggestionKind?] = [nil, .similar, .screenshots, .duplicates]
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories.indices, id: \.self) { index in
                        let kind = categories[index]
                        let selected = filter == kind
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { filter = kind }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: categorySymbol(kind))
                                    .font(.system(size: 17, weight: .regular))
                                if selected {
                                    Text(categoryTitle(kind))
                                        .font(.subheadline.weight(.semibold))
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                            .frame(minWidth: selected ? 0 : 58, minHeight: 44)
                            .padding(.horizontal, selected ? 17 : 0)
                            .background {
                                Capsule().fill(selected
                                    ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.17, green: 0.43, blue: 0.72),
                                                                              Color(red: 0.54, green: 0.31, blue: 0.68)],
                                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)))
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(categoryTitle(kind))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: filter) { _, value in
                guard let index = categories.firstIndex(of: value) else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(height: 48)
        .accessibilityLabel(String(localized: "建议类型"))
    }

    private var sortingMenu: some View {
        Menu {
            ForEach(SuggestionListOrder.allCases, id: \.rawValue) { order in
                Button {
                    listOrderRaw = order.rawValue
                    shuffledGroupIDs.removeAll()
                } label: {
                    if listOrder == order && shuffledGroupIDs.isEmpty {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(shuffledGroupIDs.isEmpty ? listOrder.title : String(localized: "随机顺序"))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
        }
        .textCase(nil)
        .accessibilityLabel(String(localized: "建议排序"))
    }

    private func categoryTitle(_ kind: SuggestionKind?) -> String {
        switch kind {
        case nil: String(localized: "全部")
        case .similar: String(localized: "相似")
        case .screenshots: String(localized: "截图")
        case .duplicates: String(localized: "副本")
        }
    }

    private func categorySymbol(_ kind: SuggestionKind?) -> String {
        switch kind {
        case nil: "square.grid.2x2"
        case .similar: "photo.on.rectangle.angled"
        case .screenshots: "rectangle.dashed"
        case .duplicates: "doc.on.doc"
        }
    }

    private var categoryExplanation: String {
        switch filter {
        case nil:
            String(localized: "相似画面、超过 90 天的临时截图，以及原始文件完全相同的副本。")
        case .similar:
            String(localized: "同一场景连拍或画面很接近的照片会放在一起。修图版和原图可以都留。")
        case .screenshots:
            String(localized: "只看超过 90 天、有明确临时信息的截图，例如订单结果、取件码、验证码、已送达物流、过期活动或优惠券；逐张判断是否还需要。")
        case .duplicates:
            String(localized: "只有原始文件内容完全相同才算副本。修图软件导出的照片不会仅凭画面相似被当成副本。")
        }
    }

    private var suggestionDetails: String {
        var details = [
            categoryExplanation,
            String(localized: "清理建议在设备上生成，分析过程无需将照片发送到外部服务。"),
            String(localized: "建议顺序会根据你在本机的完成和跳过操作微调，可随时重置。")
        ]
        if library.authorizationStatus == .limited {
            details.append(String(localized: "建议仅来自当前获准访问的照片。"))
        }
        if let error = suggestions.backgroundScheduleError {
            details.append(error)
        }
        return details.joined(separator: "\n\n")
    }

    private var emptyContent: some View {
        let oldScreenshots = library.assets.contains {
            $0.mediaSubtypes.contains(.photoScreenshot) &&
            ($0.creationDate ?? .distantFuture) < Date.now.addingTimeInterval(-90 * 86_400)
        }
        return ContentUnavailableView {
            Label(String(localized: suggestions.isScanning ? "正在寻找建议" : "暂无清理建议"),
                  systemImage: filter.map { categorySymbol($0) } ?? "wand.and.stars")
        } description: {
            if filter == .screenshots {
                Text(suggestions.isScanning
                     ? String(localized: "正在优先检查旧截图；找到临时信息后会出现在这里。")
                     : !suggestions.hasScanned
                        ? String(localized: "旧截图还没有检查完；打开应用时会继续，符合条件的内容会陆续出现。")
                        : oldScreenshots
                        ? String(localized: "旧截图已检查完，暂未识别出明确的临时信息。普通截图仍可按月份查看。")
                        : String(localized: "图库中暂无超过 90 天的截图，最近的截图不会进入这里。"))
            } else if filter == .duplicates {
                Text(suggestions.isScanning
                     ? String(localized: "正在核对原始文件；画面相似不等于副本。")
                     : String(localized: "还没有确认原始文件完全相同的副本。"))
            } else {
                Text(suggestions.isScanning
                     ? String(localized: "分析在本机进行，找到照片组后即可开始审核。")
                     : String(localized: "目前没有符合条件的未处理照片。你仍可以按月份或随机审核。"))
            }
        }
    }

    private func session(_ groups: [CleanupSuggestion], startingAt group: CleanupSuggestion? = nil,
                         selection: Binding<String?>? = nil,
                         paneUndoState: Binding<SuggestionPaneUndoState>? = nil,
                         paneUndoRequest: Int? = nil, paneSkipRequest: Int? = nil) -> some View {
        SuggestedReviewSessionView(groups: groups, startingAt: group,
                                   library: library, reviews: reviews, sizes: sizes,
                                   albumService: albumService, albumAssignments: albumAssignments,
                                   selection: selection,
                                   paneUndoState: paneUndoState, paneUndoRequest: paneUndoRequest,
                                   paneSkipRequest: paneSkipRequest)
    }
}

private struct SuggestionSessionDestination: Hashable {
    let groupID: String
}

private enum SuggestionListOrder: String, CaseIterable {
    case recommended, oldestFirst, newestFirst

    var title: String {
        switch self {
        case .recommended: String(localized: "按推荐顺序")
        case .oldestFirst: String(localized: "按时间 · 由早到晚")
        case .newestFirst: String(localized: "按时间 · 由晚到早")
        }
    }
}

private struct SuggestionScanStatusView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let isVisible: Bool
    @Environment(PhotoSuggestionService.self) private var suggestions
    @Environment(\.scenePhase) private var scenePhase

    private var reportsLiveProgress: Bool { isVisible && scenePhase == .active }

    private var statusTitle: String? {
        if suggestions.isScanning { return String(localized: "正在检查你的照片…") }
        if suggestions.isManuallyPaused { return String(localized: "照片检查已暂停。") }
        if suggestions.isEnergyPaused { return String(localized: "设备温度较高，检查稍后继续。") }
        if !suggestions.hasScanned { return String(localized: "等待继续检查…") }
        return nil
    }

    var body: some View {
        let progress = suggestions.displayedProgress
        let percent = progress.percentage(complete: suggestions.hasScanned)
        let progressDetail = percent.flatMap { value -> String? in
            guard progress.total > 0, value < 100 else { return nil }
            return String(format: String(localized: "%d%%（%@/%@）"), value,
                          progress.checked.formatted(), progress.total.formatted())
        }
        VStack(alignment: .leading, spacing: 6) {
            if let statusTitle {
                Text(verbatim: statusTitle + (progressDetail.map { " \($0)" } ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            if suggestions.isManuallyPaused ||
                (!suggestions.isScanning && !suggestions.isEnergyPaused && !suggestions.hasScanned) {
                Button(String(localized: "继续分析"), systemImage: "play") {
                    suggestions.start(library: library, reviews: reviews)
                }
                .font(.subheadline)
            }
        }
        .onChange(of: reportsLiveProgress, initial: true) { _, visible in
            suggestions.setProgressVisible(visible)
        }
        .onAppear { suggestions.setProgressVisible(reportsLiveProgress) }
        .onDisappear { suggestions.setProgressVisible(false) }
    }
}

private struct SuggestionRow: View {
    let group: CleanupSuggestion
    let library: PhotoLibraryService
    let reviews: ReviewStore
    @Environment(PhotoSuggestionService.self) private var suggestions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var visibleIDs: [String] { suggestions.visibleAssetIDs(in: group, library: library, reviews: reviews) }

    var body: some View {
        let ids = visibleIDs
        let thumbnailSize: CGFloat = dynamicTypeSize.isAccessibilitySize ? 72 : 64
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let fiveTileSize = (geometry.size.width - 6 * 4) / 5
                let maximumSlots = fiveTileSize >= (dynamicTypeSize.isAccessibilitySize ? 68 : 58) ? 5 : 4
                let tileSize = min(thumbnailSize, (geometry.size.width - 6 * CGFloat(maximumSlots - 1)) / CGFloat(maximumSlots))
                let photoCount = min(ids.count, ids.count > maximumSlots ? maximumSlots - 1 : maximumSlots)
                let remainingCount = ids.count - photoCount
                HStack(spacing: 6) {
                    ForEach(Array(ids.prefix(photoCount)), id: \.self) { id in
                        if let asset = library.asset(with: id) {
                            AssetImageView(asset: asset, library: library, contentMode: .fill,
                                           targetSize: CGSize(width: 240, height: 240),
                                           requiresFullQuality: group.kind == .similar)
                                .frame(width: tileSize, height: tileSize)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                        }
                    }
                    if remainingCount > 0 {
                        ZStack {
                            Color(uiColor: .tertiarySystemFill)
                            if let asset = library.asset(with: ids[photoCount]) {
                                AssetImageView(asset: asset, library: library, contentMode: .fill,
                                               targetSize: CGSize(width: 180, height: 180))
                                    .frame(width: tileSize, height: tileSize)
                                    .clipped()
                                    .blur(radius: 18, opaque: true)
                            }
                            Color.black.opacity(0.38)
                            Text("+\(remainingCount)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                        .frame(width: tileSize, height: tileSize)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: thumbnailSize)
            Label {
                Text(String(localized: "\(group.displayTitle) · \(ids.count) 张"))
            } icon: {
                Image(systemName: group.kind.symbol)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

extension CleanupSuggestion {
    var displayTitle: String {
        switch reason {
        case .possibleVersions: String(localized: "相近版本")
        case .olderOrders: String(localized: "旧订单截图")
        case .olderPickupCodes: String(localized: "旧取件码截图")
        case .olderVerificationCodes: String(localized: "旧验证码截图")
        case .olderDeliveries: String(localized: "旧物流截图")
        case .expiredOffers: String(localized: "过期优惠券截图")
        case .pastEvent: String(localized: "过期活动截图")
        default: kind.title
        }
    }
}
