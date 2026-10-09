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
    let onBackToHome: () -> Void

    @Environment(PhotoSuggestionService.self) private var suggestions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter: SuggestionKind?
    @State private var isVisible = false
    @State private var shuffledGroupIDs: [String] = []
    @State private var showingSuggestionInfo = false

    private var groups: [CleanupSuggestion] {
        let source = suggestions.availableGroups(library: library, reviews: reviews)
        let positions = Dictionary(uniqueKeysWithValues: shuffledGroupIDs.enumerated().map { ($0.element, $0.offset) })
        return source.enumerated().sorted { left, right in
            if !shuffledGroupIDs.isEmpty {
                let a = positions[left.element.id] ?? Int.max
                let b = positions[right.element.id] ?? Int.max
                if a != b { return a < b }
            }
            let a = categoryRank(left.element.kind)
            let b = categoryRank(right.element.kind)
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
    }
    var body: some View {
        let allGroups = groups
        let filteredGroups = allGroups.filter { filter == nil || $0.kind == filter }
        let resumedGroups: [CleanupSuggestion] = {
            guard shuffledGroupIDs.isEmpty else { return [] }
            let lookup = Dictionary(uniqueKeysWithValues: filteredGroups.map { ($0.id, $0) })
            return suggestions.resumeGroupIDs.compactMap { lookup[$0] }
        }()
        let visiblePhotoCount = Set(allGroups.flatMap {
            suggestions.visibleAssetIDs(in: $0, library: library, reviews: reviews)
        }).count
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "\(allGroups.count) 组建议 · \(visiblePhotoCount) 张照片"))
                        .font(.headline)
                        .monospacedDigit()
                    SuggestionScanStatusView(library: library, reviews: reviews)
                }
                .padding(.vertical, 4)
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
                    ForEach(filteredGroups) { group in
                        NavigationLink {
                            session(filteredGroups, startingAt: group)
                        } label: {
                            SuggestionRow(group: group, library: library, reviews: reviews)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(String(localized: "跳过"), systemImage: "forward.end") { suggestions.skip(group) }
                                .tint(.secondary)
                        }
                    }
                }
            } header: {
                if !filteredGroups.isEmpty { Text(String(localized: shuffledGroupIDs.isEmpty ? "按推荐顺序" : "随机顺序")) }
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
        .listSectionSpacing(0)
        .navigationTitle(String(localized: "清理建议"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if showsBackToHome {
                    Button(action: onBackToHome) {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel(String(localized: "返回首页"))
                }
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
                } label: { Image(systemName: shuffledGroupIDs.isEmpty ? "shuffle" : "arrow.up.arrow.down") }
                .disabled(shuffledGroupIDs.isEmpty && allGroups.count < 2)
                .accessibilityLabel(String(localized: shuffledGroupIDs.isEmpty ? "随机排列建议" : "恢复推荐顺序"))
            }
            ToolbarItem(placement: .topBarTrailing) {
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
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(String(localized: "建议选项"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !filteredGroups.isEmpty {
                NavigationLink {
                    session(filteredGroups, startingAt: resumedGroups.first)
                } label: {
                    Label(String(localized: resumedGroups.isEmpty ? "开始推荐审核" : "继续推荐审核"), systemImage: "play.fill")
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
        .task(id: library.revision) { suggestions.startIfNeeded(library: library, reviews: reviews) }
        .onAppear { isVisible = true }
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

    private func categoryRank(_ kind: SuggestionKind) -> Int {
        switch kind {
        case .similar: 0
        case .screenshots: 1
        case .duplicates: 2
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
            String(localized: "清理建议在设备上生成，分析过程无需将照片发送到外部服务。")
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
                  systemImage: filter == .screenshots ? "rectangle.dashed" : "wand.and.stars")
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

    private func session(_ groups: [CleanupSuggestion], startingAt group: CleanupSuggestion? = nil) -> some View {
        SuggestedReviewSessionView(groups: groups, startingAt: group,
                                   library: library, reviews: reviews, sizes: sizes,
                                   albumService: albumService, albumAssignments: albumAssignments)
    }
}

private struct SuggestionScanStatusView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    @Environment(PhotoSuggestionService.self) private var suggestions

    var body: some View {
        Group {
            if suggestions.isScanning {
                if let percent = suggestions.scanProgressPercent {
                    Text(String(format: String(localized: "正在检查你的照片… %d%%"), percent))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(String(localized: "正在检查你的照片…"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if suggestions.isManuallyPaused {
                Text(String(localized: "照片检查已暂停。"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(String(localized: "继续分析"), systemImage: "play") {
                    suggestions.start(library: library, reviews: reviews)
                }
                .font(.subheadline)
            } else if suggestions.isEnergyPaused {
                Text(String(localized: "设备温度较高，降温后会继续检查照片。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if !suggestions.hasScanned {
                if let percent = suggestions.scanProgressPercent, percent > 0 {
                    Text(String(format: String(localized: "已检查到 %d%%，等待继续。"), percent))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Button(String(localized: "继续分析"), systemImage: "play") {
                    suggestions.start(library: library, reviews: reviews)
                }
                .font(.subheadline)
            }
        }
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
