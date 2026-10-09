import Photos
import SwiftUI

struct SuggestedReviewSessionView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore

    @Environment(PhotoSuggestionService.self) private var suggestions
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSummaryTab) private var openSummaryTab
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var groups: [CleanupSuggestion]
    @State private var index: Int
    @State private var keeping = Set<String>()
    @State private var groupDrafts: [String: Set<String>] = [:]
    @State private var undoEntries: [(index: Int, token: UUID, wholeGroup: Bool)] = []
    @State private var startedUndoToken: UUID?
    @State private var gallery: SuggestionGallerySelection?
    @State private var showingError = false

    init(groups: [CleanupSuggestion], startingAt startGroup: CleanupSuggestion? = nil,
         library: PhotoLibraryService, reviews: ReviewStore, sizes: AssetSizeService,
         albumService: PhotoAlbumService, albumAssignments: PendingAlbumAssignmentStore) {
        _groups = State(initialValue: groups)
        _index = State(initialValue: SuggestionReviewQueue.initialIndex(of: startGroup, in: groups))
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
            $0.isFavorite || reviews.isPendingFavorite($0.localIdentifier) || reviews.decision(for: $0.localIdentifier) == .keep ||
            albumAssignments.assignment(for: $0.localIdentifier) != nil
        }.map(\.localIdentifier))
    }
    private var selectedIDs: Set<String> { keeping.union(protectedIDs).intersection(Set(currentAssets.map(\.localIdentifier))) }
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
    private var undoTitle: String {
        String(localized: undoEntries.last?.wholeGroup == false ? "撤销上一张" : "撤销整组决定")
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
                        if !undoEntries.isEmpty {
                            Button(undoTitle, systemImage: "arrow.uturn.backward") { undo() }
                                .disabled(!canUndo)
                        }
                    }
                }
            } else {
                comparisonContent
                    .navigationTitle(String(localized: "推荐审核"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { comparisonToolbar }
            }
        }
        .onAppear { startedUndoToken = reviews.latestUndoToken; rememberSession() }
        .onChange(of: suggestions.groups) { _, refreshed in
            let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
            groups = groups.map { byID[$0.id] ?? $0 }
        }
        .task(id: group?.id) {
            if let group { await suggestions.prioritizeRecommendation(for: group, library: library) }
        }
        .task(id: index, priority: .utility) { await prefetchNeighboringGroups() }
        .sheet(item: $gallery) { selection in
            if let group {
                SuggestionPhotoGallery(group: group, assetIDs: currentAssets.map(\.localIdentifier),
                                       initialID: selection.id, library: library, sizes: sizes,
                                       keeping: $keeping, protectedIDs: protectedIDs,
                                       hasNextGroup: groups.indices.contains(index + 1),
                                       canAdvance: canCommit, canKeepAll: canKeepAll, canKeepNone: canKeepNone) { choice in
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
        .alert(String(localized: "操作未完成"), isPresented: $showingError) {
            Button(String(localized: "知道了"), role: .cancel) { reviews.clearError() }
        } message: {
            Text(reviews.errorMessage ?? String(localized: "照片或处理状态已变化，请重新检查这一组。"))
        }
    }

    @ViewBuilder
    private var comparisonContent: some View {
        if let group {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(index + 1) / \(groups.count) · \(group.displayTitle)")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        Text(String(localized: "选择要保留的照片"))
                            .font(.title2.weight(.bold))
                    }
                    if currentAssets.count != group.assetIDs.count {
                        Label(String(localized: "部分照片已无法访问，请跳过本组并更新建议。"), systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 16) {
                        ForEach(currentAssets, id: \.localIdentifier) { asset in photoCell(asset, group: group) }
                    }
                }
                .padding(20)
            }
            .id(group.id)
            .transition(.opacity)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard abs(horizontal) >= 70, abs(horizontal) > abs(vertical) * 1.4,
                          horizontal < 0 || value.startLocation.x > 36 else { return }
                    browseGroup(horizontal < 0 ? 1 : -1)
                }
            )
            .accessibilityAction(named: String(localized: "上一组")) { browseGroup(-1) }
            .accessibilityAction(named: String(localized: "下一组")) { browseGroup(1) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    (dynamicTypeSize.isAccessibilitySize
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
                        .disabled(!canKeepNone || !selectedIDs.isEmpty)
                        .accessibilityHint(String(localized: "本组照片会加入待删清单，确认后才从图库删除。"))
                    }

                    Button { _ = commit(keeping: selectedIDs) } label: {
                        Text(selectedIDs.isEmpty
                             ? String(localized: "先选择要保留的照片")
                             : String(localized: "保留 \(selectedIDs.count) 张，其余 \(currentAssets.count - selectedIDs.count) 张加入待删"))
                            .font(.headline)
                            .foregroundStyle(canCommit ? Color(uiColor: .systemBackground) : Color.primary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(.primary)
                    .disabled(!canCommit)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        } else {
            ContentUnavailableView {
                Label(String(localized: "本轮建议已审核"), systemImage: "checkmark.circle")
            } description: {
                Text(String(localized: "待删照片已加入清单，确认后才会从系统图库删除。"))
            } actions: {
                Button(String(localized: "查看清单"), systemImage: "checklist") { openSummaryTab?() }
                    .buttonStyle(.glassProminent)
                    .tint(.primary)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                Button(String(localized: "完成")) { dismiss() }
            }
        }
    }

    @ToolbarContentBuilder
    private var comparisonToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !undoEntries.isEmpty {
                Button(undoTitle, systemImage: "arrow.uturn.backward") { undo() }
                    .disabled(!canUndo)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let group {
                Menu {
                    if group.recommendedKeepID != nil {
                        Button(String(localized: "采用保留建议"), systemImage: "wand.and.stars") {
                            if let id = group.recommendedKeepID { keeping = protectedIDs.union([id]); haptic() }
                        }
                    }
                    Button(String(localized: "跳过本组"), systemImage: "forward.end") { skip() }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(String(localized: "本组操作"))
            }
        }
    }

    private func photoCell(_ asset: PHAsset, group: CleanupSuggestion) -> some View {
        let id = asset.localIdentifier
        let selected = selectedIDs.contains(id)
        let protected = protectedIDs.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            AssetImageView(asset: asset, library: library, contentMode: .fit,
                           targetSize: CGSize(width: 1_500, height: 1_500), requiresFullQuality: true)
                .frame(maxWidth: .infinity)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 240 : 170)
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

            if let score = group.visionScoreDescription(for: id) {
                Label(score, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if group.kind == .similar && group.aestheticEvaluationComplete {
                Label(String(localized: "Vision 暂无本地评分"), systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if group.recommendedKeepID == id {
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
        let recorded = allowEmptyKeep
            ? protectedIDs.isEmpty && reviews.stageGroupForDeletion(group.assetIDs)
            : reviews.decideGroup(group.assetIDs, keeping: selected.union(protectedIDs))
        guard recorded else { showingError = true; return false }
        if let token = reviews.latestUndoToken { undoEntries.append((index, token, true)) }
        haptic()
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
        keeping = group.flatMap { groupDrafts[$0.id] } ?? []
        startedUndoToken = reviews.latestUndoToken
        rememberSession()
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
            if !suggestions.skippedIDs.contains(candidate.id), !hasPendingDeletion,
               suggestions.isCurrent(candidate, library: library) {
                gallery = nil
                if let group { groupDrafts[group.id] = keeping }
                withAnimation(.easeInOut(duration: 0.18)) {
                    index = target
                    keeping = groupDrafts[candidate.id] ?? []
                }
                startedUndoToken = reviews.latestUndoToken
                rememberSession()
                haptic()
                return
            }
            target += direction
        }
    }

    private func finishScreenshots() {
        if let token = reviews.latestUndoToken, token != startedUndoToken {
            undoEntries.append((index, token, false))
        }
        advance()
    }

    private func undo() {
        guard let entry = undoEntries.last, reviews.undo(matching: entry.token) else { return }
        index = entry.index
        undoEntries.removeLast()
        keeping.removeAll()
        startedUndoToken = reviews.latestUndoToken
        rememberSession()
        haptic()
    }

    private func rememberSession() { suggestions.rememberSession(groups, index: index) }
    private func haptic() { if settings.hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() } }
}

private struct SuggestionGallerySelection: Identifiable { let id: String }

private extension CleanupSuggestion {
    func visionScoreDescription(for assetID: String) -> String? {
        guard kind == .similar, let score = aestheticScores[assetID] else { return nil }
        let value = score.formatted(.number.precision(.fractionLength(2)))
        return String(localized: "Vision 评分 \(value)")
    }

    func recommendationDetail(for assetID: String) -> String? {
        guard recommendedKeepID == assetID, let recommendationBasis else { return nil }
        switch recommendationBasis {
        case .protected:
            return String(localized: "你已收藏或保留这张，建议继续留着；其他版本也可以一起留。")
        case .identicalResources:
            return String(localized: "原始文件内容完全相同，留这一张即可。")
        case .resolution:
            return String(localized: "Vision 评分很接近，这张保留的像素更多，裁剪余地更大。")
        case .visionAesthetics:
            guard aestheticScores[assetID] != nil, let aestheticLead else { return nil }
            return aestheticLead < 0.08
                ? String(localized: "这张的 Vision 评分略高，但差距很小。比较表情、光线和构图；喜欢的版本可以都留。")
                : String(localized: "这张的 Vision 评分明显更高，建议优先保留。喜欢的其他版本也可以一起留。")
        }
    }
}

private struct SuggestionFileSizeLabel: View {
    let asset: PHAsset
    let sizes: AssetSizeService
    @State private var bytes: Int64?

    var body: some View {
        Group {
            if let bytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            } else {
                Text(String(localized: "大小暂不可用"))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .task(id: asset.localIdentifier, priority: .utility) {
            bytes = sizes.knownSize(for: asset)
            if bytes == nil { bytes = await sizes.automaticLocalSize(for: asset) }
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
    let onAdvance: (GalleryGroupDecision) -> GalleryAdvanceResult
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedID: String
    @State private var showingInfo = false

    private var recommendationReason: String? {
        guard let recommendedKeepID = group.recommendedKeepID else { return nil }
        return group.recommendationDetail(for: recommendedKeepID)
    }

    init(group: CleanupSuggestion, assetIDs: [String], initialID: String, library: PhotoLibraryService,
         sizes: AssetSizeService, keeping: Binding<Set<String>>, protectedIDs: Set<String>,
         hasNextGroup: Bool, canAdvance: Bool, canKeepAll: Bool, canKeepNone: Bool,
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
        self.onAdvance = onAdvance
        _selectedID = State(initialValue: initialID)
    }

    var body: some View {
        NavigationStack {
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
            .tabViewStyle(.page)
            .background(.black)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .bottomLeading) {
                        Color.clear
                        if let recommendationReason {
                            recommendationCallout(recommendationReason)
                                .opacity(selectedID == group.recommendedKeepID ? 1 : 0)
                                .accessibilityHidden(selectedID != group.recommendedKeepID)
                        }
                    }
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 100)
                    HStack(spacing: 12) {
                        if let asset = library.asset(with: selectedID) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.visionScoreDescription(for: selectedID) ??
                                     (group.kind == .similar ? "Vision —" : " "))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.7))
                                    .accessibilityLabel(group.kind == .similar && group.aestheticScores[selectedID] == nil
                                        ? String(localized: "Vision 暂无本地评分")
                                        : group.visionScoreDescription(for: selectedID) ?? "")
                                    .accessibilityHidden(group.kind != .similar)
                                SuggestionFileSizeLabel(asset: asset, sizes: sizes)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        Spacer(minLength: 0)
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
                    galleryActions
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .top)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.black)
            }
            .onChange(of: assetIDs) { _, ids in
                if !ids.contains(selectedID), let first = ids.first { selectedID = first }
            }
            .navigationTitle(String(localized: "\((assetIDs.firstIndex(of: selectedID) ?? 0) + 1) / \(assetIDs.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel(String(localized: "返回建议审核"))

                    Button(String(localized: "照片信息"), systemImage: "info.circle") { showingInfo = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
            .sheet(isPresented: $showingInfo) {
                if let asset = library.asset(with: selectedID) {
                    NavigationStack {
                        ScrollView { AssetInfoView(asset: asset, sizes: sizes).padding(20) }
                            .navigationTitle(String(localized: "照片信息"))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { showingInfo = false } } }
                    }
                }
            }
        }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var galleryActions: some View {
        if let position = assetIDs.firstIndex(of: selectedID), position < assetIDs.count - 1 {
            Button {
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
            VStack(spacing: 8) {
                let selectedCount = keeping.union(protectedIDs).intersection(Set(assetIDs)).count
                if selectedCount > 0 && selectedCount < assetIDs.count {
                    Button { advance(.selected) } label: {
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

    private func groupAction(_ title: String, choice: GalleryGroupDecision, enabled: Bool) -> some View {
        Button { advance(choice) } label: {
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
        switch onAdvance(choice) {
        case .failed: break
        case .dismiss: dismiss()
        case .next(let identifier): selectedID = identifier
        }
    }
}

private enum GalleryGroupDecision: Equatable { case selected, all, none }
private enum GalleryAdvanceResult { case failed, next(String), dismiss }

private struct SuggestionZoomPhoto: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    let allowNetwork: Bool
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var retry = 0

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
                    Button(String(localized: "重试")) { retry += 1 }
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
            if let requestedImage {
                image = requestedImage
                library.cacheReviewPreview(requestedImage, for: asset)
            }
            if !Task.isCancelled { loaded = true }
        }
        .accessibilityLabel(String(localized: "照片预览"))
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
