import Foundation
import Photos
import SwiftUI

struct LibraryHomeView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore
    let onOpenSummary: () -> Void
    let onOpenSuggestions: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(ReviewResumeStore.self) private var resume

    @State private var isRequestingAccess = false
    @State private var isRefreshing = false
    @State private var showingAllMonths = false
    @State private var showingAllYears = false
    @State private var showingAllAlbums = false
    @State private var timeGrouping: TimeGrouping = .month

    private var isAuthorized: Bool {
        switch library.authorizationStatus {
        case .authorized, .limited:
            true
        default:
            false
        }
    }

    private var pendingCount: Int {
        reviews.identifiers(with: .later).count
    }

    private var pendingDeleteCount: Int {
        reviews.identifiers(with: .delete)
            .filter { library.asset(with: $0) != nil }
            .count
    }

    private var pendingFavoriteCount: Int {
        reviews.pendingFavoriteIdentifiers
            .filter { library.asset(with: $0) != nil }
            .count
    }

    private var pendingConfirmationCount: Int {
        pendingDeleteCount + pendingFavoriteCount + albumAssignments.count +
            LivePhotoConversionManager.shared.visiblePendingConversions(reviews: reviews).count +
            (LivePhotoConversionManager.shared.journalError == nil ? 0 : 1)
    }

    private var pendingSummary: String {
        let parts: [(String, Int)] = [
            (String(localized: "待删除"), pendingDeleteCount),
            (String(localized: "待收藏"), pendingFavoriteCount),
            (String(localized: "待整理"), albumAssignments.count),
            (String(localized: "静态转换"), LivePhotoConversionManager.shared.visiblePendingConversions(reviews: reviews).count),
            (String(localized: "转换记录待检查"), LivePhotoConversionManager.shared.journalError == nil ? 0 : 1)
        ]
        return parts.filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: " · ")
    }

    private var unreviewedCount: Int {
        library.assets.filter { reviews.decision(for: $0.localIdentifier) == nil }.count
    }

    private var reviewedCount: Int {
        library.assets.filter {
            let decision = reviews.decision(for: $0.localIdentifier)
            return decision == .keep || decision == .delete
        }.count
    }

    private var monthBuckets: [MonthBucket] { library.monthBuckets }

    private var visibleMonthBuckets: [MonthBucket] {
        guard showingAllMonths || monthBuckets.count <= 6 else {
            return Array(monthBuckets.prefix(6))
        }
        return monthBuckets
    }

    private var yearBuckets: [MonthBucket] { library.yearBuckets }

    private var visibleYearBuckets: [MonthBucket] {
        showingAllYears ? yearBuckets : Array(yearBuckets.prefix(6))
    }

    private var visibleAlbums: [LibraryAlbum] {
        guard showingAllAlbums || regularAlbums.count <= 8 else {
            return Array(regularAlbums.prefix(8))
        }
        return regularAlbums
    }

    private var regularAlbums: [LibraryAlbum] {
        library.albums.filter { $0.smartSubtypeRawValue == nil }
    }

    private var additionalTypeAlbums: [LibraryAlbum] {
        let existingTypes: Set<Int> = [
            PHAssetCollectionSubtype.smartAlbumVideos.rawValue,
            PHAssetCollectionSubtype.smartAlbumScreenshots.rawValue,
            PHAssetCollectionSubtype.smartAlbumLivePhotos.rawValue,
            PHAssetCollectionSubtype.smartAlbumScreenRecordings.rawValue,
            PHAssetCollectionSubtype.smartAlbumSelfPortraits.rawValue
        ]
        let utilityAlbums: Set<Int> = [
            PHAssetCollectionSubtype.smartAlbumGeneric.rawValue,
            PHAssetCollectionSubtype.smartAlbumUserLibrary.rawValue,
            PHAssetCollectionSubtype.smartAlbumRecentlyAdded.rawValue,
            PHAssetCollectionSubtype.smartAlbumAllHidden.rawValue,
            PHAssetCollectionSubtype.smartAlbumUnableToUpload.rawValue
        ]
        return library.albums.filter { album in
            guard let subtype = album.smartSubtypeRawValue else { return false }
            return !existingTypes.contains(subtype) && !utilityAlbums.contains(subtype)
        }
    }

    private var availableMediaCategories: [CategoryEntry] {
        MediaCategory.allCases.compactMap { category in
            let count = library.assets(in: .category(category)).count
            return count > 0 ? CategoryEntry(category: category, count: count) : nil
        }
    }

    private var unreviewedMonthBuckets: [MonthBucket] {
        monthBuckets.filter { bucket in
            bucket.assets.contains { reviews.decision(for: $0.localIdentifier) == nil }
        }
    }

    private var continueMonth: Date? {
        guard let lastMonth = resume.lastMonth else { return nil }
        let unfinished = unreviewedMonthBuckets
        return unfinished.first(where: { $0.date == lastMonth })?.date
            ?? unfinished.first(where: { $0.date < lastMonth })?.date
            ?? unfinished.first?.date
    }

    private var continueTarget: (scope: LibraryScope, title: String, remaining: Int)? {
        if let scope = resume.lastScope {
            let remaining = library.assets(in: scope)
                .filter { reviews.decision(for: $0.localIdentifier) == nil }
                .count
            if remaining > 0 {
                return (scope, continueTitle(for: scope), remaining)
            }
        }

        if let month = continueMonth ?? unreviewedMonthBuckets.first?.date {
            let remaining = library.assets(in: .month(month))
                .filter { reviews.decision(for: $0.localIdentifier) == nil }
                .count
            return (.month(month), month.zeyingHomeMonthTitle, remaining)
        }
        guard unreviewedCount > 0 else { return nil }
        return (.all, String(localized: "全部照片"), unreviewedCount)
    }

    private func continueTitle(for scope: LibraryScope) -> String {
        switch scope {
        case .all: String(localized: "全部照片")
        case .random: String(localized: "随机清理")
        case .month(let date): date.zeyingHomeMonthTitle
        case .year(let date): date.zeyingYearTitle
        case .album(let identifier):
            library.albums.first(where: { $0.id == identifier })?.title ?? String(localized: "相簿")
        case .category(let category): category.title
        case .later: String(localized: "待决定")
        }
    }

    var body: some View {
        Group {
            if isAuthorized {
                authorizedContent
            } else {
                authorizationContent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: HomeDestination.self) { destination in
            switch destination {
            case .pending:
                PendingDecisionsView(
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments
                )
                    .toolbar(.visible, for: .navigationBar)
            case .scope(let scope):
                ReviewQueueView(
                    scope: scope,
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments
                )
                .toolbar(.visible, for: .navigationBar)
            }
        }
        .task(id: isAuthorized) {
            guard isAuthorized else { return }
            await library.ensureLoaded()
        }
    }

    private var authorizedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        homeTitle
                        overviewHeader
                    }
                    VStack(spacing: 12) {
                        cleanupTotalsCard
                        if library.authorizationStatus == .limited {
                            limitedAccessCard
                        }
                        if library.hasLoaded {
                            if library.assets.isEmpty {
                                emptyLibraryCard
                            } else if unreviewedCount > 0 {
                                continueCard
                            }
                            if pendingCount > 0 {
                                undecidedCard
                            }
                            if pendingConfirmationCount > 0 {
                                pendingConfirmationCard
                            }
                        } else {
                            loadingCard
                        }
                    }
                }
                if library.hasLoaded {
                    monthSection
                    albumSection
                    categorySection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            isRefreshing = true
            await library.refresh()
            isRefreshing = false
        }
        .safeAreaPadding(.bottom, 16)
        .overlay(alignment: .top) {
            if isRefreshing {
                ProgressView()
                    .padding(.top, 8)
            }
        }
    }

    private var homeTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(localized: "择影"))
                .font(.largeTitle.weight(.bold))
            if Bundle.main.preferredLocalizations.first == "zh-Hans" {
                Text("Swipick")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var limitedAccessCard: some View {
        Button {
            presentLimitedLibraryPicker()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checklist.checked")
                    .font(.headline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .zeyingGlass(in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "管理可访问照片"))
                        .font(.subheadline.weight(.semibold))
                    Text(String(localized: "当前只显示你允许择影访问的照片"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .zeyingGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityLabel(String(localized: "管理可访问照片"))
        .accessibilityHint(String(localized: "打开系统照片选择器，调整择影可访问的照片"))
    }

    private func presentLimitedLibraryPicker() {
        ZeyingLimitedLibraryAccess.present(using: library)
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if library.hasLoaded {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        Button(action: onOpenSuggestions) {
                            Label(String(localized: "清理建议"), systemImage: "wand.and.stars")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .frame(minHeight: 34)
                                .background(RandomCleanupAccent.buttonGradient, in: Capsule())
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(String(localized: "查找重复副本、相似照片和可集中检查的截图"))
                        if unreviewedCount > 0 {
                            NavigationLink(value: HomeDestination.scope(.random)) {
                                Label(String(localized: "随机清理"), systemImage: "shuffle")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .frame(minHeight: 34)
                                    .homeSurface(in: Capsule())
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(String(localized: "随机排列所有未处理照片，不按时间顺序"))
                        }
                        StatPill(title: String(localized: "已决定"), value: reviewedCount, symbol: "checkmark.circle")
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                Label(String(localized: "正在读取照片…"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "正在准备你的照片…"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeyingGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "正在读取照片"))
    }

    private var cleanupTotalsCard: some View {
        let totals = reviews.cleanupTotals
        return NavigationLink {
            CleanupStatisticsView(reviews: reviews)
                .toolbar(.visible, for: .navigationBar)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Label(String(localized: "择影已清理"), systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 12) {
                            cleanupTotalItems(totals: totals)
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 6) {
                                cleanupTotalItems(totals: totals)
                            }
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                                alignment: .leading,
                                spacing: 12
                            ) {
                                cleanupTotalItems(totals: totals)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(CleanupTotalsCardButtonStyle())
        .accessibilityLabel(String(localized: "查看清理统计，已清理 \(totals.deletedPhotoCount) 张照片、\(totals.deletedVideoCount) 个视频，Live 转静态 \(LivePhotoConversionManager.shared.convertedCount) 张，已知资源大小 \(formatByteCount(totals.knownDeletedBytes))"))
        .accessibilityHint(String(localized: "打开清理统计详情"))
    }

    @ViewBuilder
    private func cleanupTotalItems(totals: CleanupTotals) -> some View {
        CleanupTotalItem(title: String(localized: "照片"), value: "\(totals.deletedPhotoCount)", symbol: "photo")
        CleanupTotalItem(title: String(localized: "视频"), value: "\(totals.deletedVideoCount)", symbol: "video")
        CleanupTotalItem(title: String(localized: "Live 转静态"), value: "\(LivePhotoConversionManager.shared.convertedCount)", symbol: "livephoto.slash")
        CleanupTotalItem(title: String(localized: "已知资源大小"), value: formatByteCount(totals.knownDeletedBytes), symbol: "externaldrive")
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var continueCard: some View {
        let target = continueTarget
        return NavigationLink(value: HomeDestination.scope(target?.scope ?? .all)) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(resume.lastScope == nil ? String(localized: "开始整理") : String(localized: "继续清理"))
                        .font(.subheadline.weight(.semibold))
                    Text(target?.title ?? String(localized: "全部照片"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 34)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .homeSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityLabel(String(localized: "\(resume.lastScope == nil ? String(localized: "开始整理") : String(localized: "继续清理"))，\(target?.title ?? String(localized: "全部照片"))，剩余 \(target?.remaining ?? unreviewedCount) 项"))
        .accessibilityHint(String(localized: "打开尚未处理的照片"))
    }

    private var emptyLibraryCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "没有可访问的照片"))
                    .font(.headline)
                Text(String(localized: "请在系统照片权限中选择要整理的照片"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeyingGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var pendingConfirmationCard: some View {
        Button(action: onOpenSummary) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "checklist")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "清单有 \(pendingConfirmationCount) 项待办"))
                        .font(.subheadline.weight(.semibold))
                    Text(pendingSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 34)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .homeSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityLabel(String(localized: "清单有 \(pendingConfirmationCount) 项待办，\(pendingSummary)"))
        .accessibilityHint(String(localized: "打开清单查看并确认操作"))
    }

    private var undecidedCard: some View {
        NavigationLink(value: HomeDestination.pending) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 34, height: 34)

                Text(String(localized: "待决定 \(pendingCount) 项"))
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 34)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .homeSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityLabel(String(localized: "待决定 \(pendingCount) 项"))
        .accessibilityHint(String(localized: "打开待决定照片并重新选择"))
    }

    private var monthSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        timeGrouping = .month
                    } label: {
                        Text(String(localized: "按月份"))
                            .foregroundStyle(timeGrouping == .month ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(timeGrouping == .month ? [.isSelected] : [])

                    Text("|")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)

                    Button {
                        timeGrouping = .year
                    } label: {
                        Text(String(localized: "按年份"))
                            .foregroundStyle(timeGrouping == .year ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(timeGrouping == .year ? [.isSelected] : [])
                }
                .font(.title3.weight(.semibold))
                Spacer()
                let hasMore = timeGrouping == .month ? monthBuckets.count > 6 : yearBuckets.count > 6
                if hasMore {
                    Button((timeGrouping == .month ? showingAllMonths : showingAllYears) ? String(localized: "收起") : String(localized: "展开全部")) {
                        if reduceMotion {
                            toggleTimeExpansion()
                        } else {
                            withAnimation(.snappy(duration: 0.24)) {
                                toggleTimeExpansion()
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "展开或收起时间列表"))
                } else {
                    Text(timeGrouping == .month ? String(localized: "最近 6 个月") : String(localized: "最近 6 年"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if (timeGrouping == .month ? monthBuckets : yearBuckets).isEmpty {
                Text(String(localized: "还没有可访问的照片"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(timeGrouping == .month ? visibleMonthBuckets : visibleYearBuckets) { bucket in
                        NavigationLink(value: HomeDestination.scope(timeGrouping == .month ? .month(bucket.date) : .year(bucket.date))) {
                            MonthRow(bucket: bucket, reviews: reviews, grouping: timeGrouping)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(timeGrouping == .month
                            ? String(localized: "打开 \(bucket.date.zeyingMonthTitle)")
                            : String(localized: "打开 \(bucket.date.zeyingYearTitle)"))
                    }
                }
            }
        }
    }

    private func toggleTimeExpansion() {
        if timeGrouping == .month { showingAllMonths.toggle() }
        else { showingAllYears.toggle() }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                Text(String(localized: "系统相簿"))
                    .font(.title3.weight(.semibold))
                Spacer()
                if regularAlbums.count > 8 {
                    Button(showingAllAlbums ? String(localized: "收起") : String(localized: "展开全部")) {
                        if reduceMotion {
                            showingAllAlbums.toggle()
                        } else {
                            withAnimation(.snappy(duration: 0.24)) {
                                showingAllAlbums.toggle()
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(showingAllAlbums ? String(localized: "收起系统相簿") : String(localized: "展开全部系统相簿"))
                } else {
                    Text(String(localized: "按相簿继续"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if regularAlbums.isEmpty {
                Text(String(localized: "没有可用的系统相簿"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(visibleAlbums) { album in
                        NavigationLink(value: HomeDestination.scope(.album(album.id))) {
                            AlbumCard(album: album, library: library)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var categorySection: some View {
        let mediaCategories = availableMediaCategories
        let smartAlbums = additionalTypeAlbums
        return VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "类型"))
                .font(.title3.weight(.semibold))

            if mediaCategories.isEmpty && smartAlbums.isEmpty {
                Text(String(localized: "当前没有可处理的类型"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(mediaCategories) { entry in
                        NavigationLink(value: HomeDestination.scope(.category(entry.category))) {
                            CategoryCard(
                                title: entry.category.title,
                                symbol: entry.category.symbol,
                                count: entry.count
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(smartAlbums) { album in
                        NavigationLink(value: HomeDestination.scope(.album(album.id))) {
                            CategoryCard(
                                title: album.title,
                                symbol: typeSymbol(for: album),
                                count: album.count
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func typeSymbol(for album: LibraryAlbum) -> String {
        switch album.smartSubtypeRawValue {
        case PHAssetCollectionSubtype.smartAlbumPanoramas.rawValue: return "pano"
        case PHAssetCollectionSubtype.smartAlbumFavorites.rawValue: return "heart.fill"
        case PHAssetCollectionSubtype.smartAlbumTimelapses.rawValue: return "timelapse"
        case PHAssetCollectionSubtype.smartAlbumBursts.rawValue: return "burst"
        case PHAssetCollectionSubtype.smartAlbumSlomoVideos.rawValue: return "slowmo"
        case PHAssetCollectionSubtype.smartAlbumDepthEffect.rawValue: return "person.crop.rectangle"
        case PHAssetCollectionSubtype.smartAlbumAnimated.rawValue: return "play.rectangle"
        case PHAssetCollectionSubtype.smartAlbumLongExposures.rawValue: return "timer"
        case PHAssetCollectionSubtype.smartAlbumRAW.rawValue: return "camera.aperture"
        case PHAssetCollectionSubtype.smartAlbumCinematic.rawValue: return "film"
        case PHAssetCollectionSubtype.smartAlbumSpatial.rawValue: return "cube.transparent"
        default:
            // Newer Photos smart albums can precede public subtype cases in the SDK.
            // Keep their icons specific when PhotoKit only supplies a localized title.
            if album.title.localizedStandardContains("Captured by Me") ||
                album.title.localizedStandardContains("我拍摄") {
                return "camera"
            }
            if album.title.localizedStandardContains("Dual Capture") ||
                album.title.localizedStandardContains("双摄") {
                return "camera.on.rectangle"
            }
            if album.title.localizedStandardContains("Recently Saved") ||
                album.title.localizedStandardContains("最近保存") {
                return "square.and.arrow.down"
            }
            return "square.stack.3d.up"
        }
    }

    private var authorizationContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            homeTitle
                .padding(.horizontal, 20)
                .padding(.top, 4)

            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(library.authorizationStatus == .notDetermined ? String(localized: "允许访问照片") : String(localized: "需要照片权限"))
                        .font(.title2.weight(.semibold))
                    Text(String(localized: "择影只会读取你选择的照片，用来整理和展示处理进度。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if library.authorizationStatus == .notDetermined {
                        Text(String(localized: "本地清晰照片会提前准备；仅存于 iCloud 的照片默认不自动下载，可在设置中开启。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if library.authorizationStatus == .denied {
                        Button(String(localized: "打开系统设置")) {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(ZeyingGlassButtonStyle())
                    } else if library.authorizationStatus == .restricted {
                        Text(String(localized: "照片访问受系统限制，请检查设备的内容与隐私访问限制。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)

                if library.authorizationStatus == .notDetermined {
                    Button(String(localized: "允许访问")) {
                        isRequestingAccess = true
                        Task {
                            await library.requestAuthorization()
                            isRequestingAccess = false
                        }
                    }
                    .buttonStyle(ZeyingGlassButtonStyle())
                    .disabled(isRequestingAccess)
                } else {
                    Text(String(localized: "请在系统设置中允许择影访问照片。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

enum HomeDestination: Hashable {
    case pending
    case scope(LibraryScope)
}

private enum TimeGrouping: Hashable {
    case month
    case year
}

private typealias MonthBucket = LibraryTimeBucket

private struct CategoryEntry: Identifiable {
    let category: MediaCategory
    let count: Int
    var id: String { category.id }
}

private struct StatPill: View {
    let title: String
    let value: Int
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text("\(value)")
                .monospacedDigit()
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .homeSurface(in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct HomeSurface<Outline: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let outline: Outline

    @ViewBuilder
    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.background(Color.white.opacity(0.08), in: outline)
        } else {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: outline)
            } else {
                // Keep the flat white version for a future lower-iOS deployment target.
                content
                    .background(.white, in: outline)
                    .overlay {
                        outline
                            .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
            }
        }
    }
}

private extension View {
    func homeSurface<Outline: InsettableShape>(in outline: Outline) -> some View {
        modifier(HomeSurface(outline: outline))
    }
}

private enum RandomCleanupAccent {
    static let blue = Color(red: 0.20, green: 0.54, blue: 0.84)
    static let purple = Color(red: 0.67, green: 0.39, blue: 0.76)

    static let buttonGradient = LinearGradient(
        colors: [Color(red: 0.17, green: 0.43, blue: 0.72), Color(red: 0.54, green: 0.31, blue: 0.68)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let borderGradient = LinearGradient(
        colors: [blue, Color(red: 0.46, green: 0.70, blue: 0.91), purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private struct CleanupTotalsCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let outline = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return configuration.label
            .homeSurface(in: outline)
            .overlay {
                outline
                    .strokeBorder(RandomCleanupAccent.borderGradient, lineWidth: 1.6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct CleanupTotalItem: View {
    let title: String
    let value: String
    let symbol: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Text(value)
                        .font(.headline.monospacedDigit())
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 18)
                    Text(value)
                        .font(.headline.monospacedDigit())
                        .lineLimit(1)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 80, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MonthRow: View {
    let bucket: MonthBucket
    let reviews: ReviewStore
    let grouping: TimeGrouping

    @Environment(\.colorScheme) private var colorScheme

    private var unreviewed: Int {
        bucket.assets.filter { reviews.decision(for: $0.localIdentifier) == nil }.count
    }

    private var undecided: Int {
        bucket.assets.filter { reviews.decision(for: $0.localIdentifier) == .later }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(grouping == .month ? bucket.date.zeyingHomeMonthTitle : bucket.date.zeyingYearTitle)
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "\(bucket.assets.count) 项"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(unreviewed == 0
                 ? (undecided > 0 ? String(localized: "已浏览") : String(localized: "已完成"))
                 : String(localized: "待处理 \(unreviewed)"))
                .font(.caption.weight(.medium))
                .foregroundStyle(unreviewed == 0 && undecided == 0 ? .green : .secondary)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            colorScheme == .dark
                ? Color.white.opacity(0.05)
                : Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AlbumCard: View {
    let album: LibraryAlbum
    let library: PhotoLibraryService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let identifier = album.coverAssetIdentifier, let asset = library.asset(with: identifier) {
                AssetImageView(
                    asset: asset,
                    library: library,
                    contentMode: .fill,
                    targetSize: CGSize(width: 720, height: 720),
                    requiresFullQuality: true,
                    allowCloudThumbnail: true
                )
                    .frame(height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.secondary.opacity(0.14))
                    .frame(height: 112)
                    .overlay { Image(systemName: "photo.on.rectangle") .foregroundStyle(.secondary) }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(String(localized: "\(album.count) 项"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(
            colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct CategoryCard: View {
    let title: String
    let symbol: String
    let count: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary)
                .background(Color.primary.opacity(0.065), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "\(count) 项"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 60)
        .padding(14)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}
