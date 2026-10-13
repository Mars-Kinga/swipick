import Photos
import SwiftUI
import UIKit

private struct SummaryEditSelection: Hashable, Identifiable {
    let id: String
}

struct ReviewSummaryView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var albumRowIconSize: CGFloat = 14
    @State private var showingFavoriteConfirmation = false
    @State private var requestedFavoriteIDs: [String] = []
    @State private var showingDeleteConfirmation = false
    @State private var requestedDeletionIDs: [String] = []
    @State private var deleteAfterPreviewDismissal: String?
    @State private var editAfterPreviewDismissal: String?
    @State private var isCommitting = false
    @State private var showingError = false
    @State private var showingAlbumConfirmation = false
    @State private var requestedAlbumIDs: [String] = []
    @State private var operationError: String?
    @State private var previewSelection: SummaryPreviewSelection?
    @State private var editSelection: SummaryEditSelection?

    private var favoriteIDs: [String] {
        reviews.pendingFavoriteIdentifiers
            .filter { library.asset(with: $0) != nil }
    }

    private var deleteIDs: [String] {
        reviews.identifiers(with: .delete)
            .filter { library.asset(with: $0) != nil }
    }

    private var albumItems: [PendingAlbumAssignment] {
        albumAssignments.assignments.filter { library.asset(with: $0.assetIdentifier) != nil }
    }

    private var unavailableAlbumItems: [PendingAlbumAssignment] {
        let accessible = Set(library.assets.map(\.localIdentifier))
        return albumAssignments.assignments.filter { !accessible.contains($0.assetIdentifier) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZeyingRootPageTitle(title: String(localized: "清单"),
                                matchesHomeExpandedPosition: true, usesHomeHeaderHeight: true)

            Group {
                if !library.hasLoaded,
                   library.authorizationStatus == .authorized || library.authorizationStatus == .limited {
                    ProgressView(String(localized: "正在读取照片…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if favoriteIDs.isEmpty && deleteIDs.isEmpty && albumItems.isEmpty &&
                            unavailableAlbumItems.isEmpty &&
                            LivePhotoConversionManager.shared.visiblePendingConversions(reviews: reviews).isEmpty &&
                            LivePhotoConversionManager.shared.journalError == nil {
                    ZeyingEmptyState(
                        symbol: "checklist",
                        title: String(localized: "暂无待确认操作"),
                        message: String(localized: "待收藏、待删除、相簿整理和未完成的静态转换会出现在这里。")
                    )
                } else {
                    summaryList
                }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $editSelection) { selection in
            ReviewQueueView(
                assetIDs: [selection.id], library: library, reviews: reviews, sizes: sizes,
                albumService: albumService, albumAssignments: albumAssignments
            )
        }
        .task {
            await library.ensureLoaded()
        }
        .overlay {
            if isCommitting {
                ProgressView(String(localized: "正在处理…"))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .zeyingGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .alert(
            String(localized: "确认收藏这些项目？"),
            isPresented: $showingFavoriteConfirmation
        ) {
            Button(String(localized: "确认收藏 \(requestedFavoriteIDs.count) 项")) {
                let identifiers = requestedFavoriteIDs
                Task { await commitFavorites(identifiers) }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "所选项目会同步到系统照片的“个人收藏”中，并从待收藏清单移除。"))
        }
        .alert(
            String(localized: requestedDeletionIDs.count == 1 ? "确认删除这个项目？" : "确认删除这些项目？"),
            isPresented: $showingDeleteConfirmation
        ) {
            Button(requestedDeletionIDs.count == 1
                   ? String(localized: "删除这个项目")
                   : String(localized: "删除 \(requestedDeletionIDs.count) 项"), role: .destructive) {
                let identifiers = requestedDeletionIDs
                Task { await commitDeletes(identifiers) }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "若启用 iCloud 照片，删除会同步到同一账户的其他设备；若为共享图库，共享成员可能看到相应变化。照片通常会按系统设置进入“最近删除”，具体保留时间和恢复条件由系统决定。"))
        }
        .alert(
            String(localized: "确认加入这些相簿？"),
            isPresented: $showingAlbumConfirmation
        ) {
            Button(String(localized: "加入相簿")) {
                let identifiers = requestedAlbumIDs
                Task { await commitAlbumAssignments(identifiers) }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "确认后，所选项目会加入对应的个人相簿。"))
        }
        .alert(String(localized: "操作未完成"), isPresented: $showingError) {
            Button(String(localized: "知道了")) { operationError = nil }
        } message: {
            Text(operationError ?? String(localized: "请稍后重试。"))
        }
        .sheet(item: $previewSelection, onDismiss: {
            if let identifier = deleteAfterPreviewDismissal {
                deleteAfterPreviewDismissal = nil
                requestedDeletionIDs = [identifier]
                showingDeleteConfirmation = true
            } else if let identifier = editAfterPreviewDismissal {
                editAfterPreviewDismissal = nil
                editSelection = SummaryEditSelection(id: identifier)
            }
        }) { selection in
            if let asset = library.asset(with: selection.assetIdentifier) {
                SummaryAssetPreviewSheet(
                    assetIDs: selection.assetIdentifiers,
                    initialID: asset.localIdentifier,
                    library: library,
                    albumAssignments: albumAssignments,
                    actionMode: selection.actionMode
                ) { identifier in
                    recoverDeletions([identifier])
                    previewSelection = nil
                } onDelete: { identifier in
                    deleteAfterPreviewDismissal = identifier
                    previewSelection = nil
                } onEdit: { identifier in
                    editAfterPreviewDismissal = identifier
                    previewSelection = nil
                } onCancelPending: { identifier in
                    switch selection.actionMode {
                    case .favorite:
                        cancelPendingFavorites([identifier])
                    case .album:
                        cancelPendingAlbumAssignments([identifier])
                    case .delete:
                        return
                    }
                    previewSelection = nil
                }
            } else {
                UnavailableSummaryPreviewSheet(
                    title: selection.actionMode == .album
                        ? albumAssignments.assignment(for: selection.assetIdentifier)?.albumTitle
                            ?? selection.actionMode.defaultTitle
                        : selection.actionMode.defaultTitle
                )
            }
        }
    }

    private var summaryList: some View {
        summaryListContent
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .refreshable {
            await library.refresh()
        }
    }

    private var summaryListContent: some View {
        List {
            PendingLiveConversionsSection(
                library: library,
                reviews: reviews,
                albumAssignments: albumAssignments
            )

            if !favoriteIDs.isEmpty {
                Section {
                    ForEach(favoriteIDs, id: \.self) { identifier in
                        summaryAssetRow(
                            identifier: identifier,
                            decision: .keep,
                            showsSeparator: identifier != favoriteIDs.last
                        )
                    }
                } header: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            favoriteSectionLabel
                            Spacer(minLength: 4)
                            favoriteSectionActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            favoriteSectionLabel
                            HStack {
                                Spacer()
                                favoriteSectionActions
                            }
                        }
                    }
                    .zeyingAlignedGroupedSectionHeader()
                    .textCase(nil)
                }
            }

            if !deleteIDs.isEmpty {
                Section {
                    ForEach(deleteIDs, id: \.self) { identifier in
                        summaryAssetRow(
                            identifier: identifier,
                            decision: .delete,
                            showsSeparator: identifier != deleteIDs.last
                        )
                    }
                } header: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            deleteSectionLabel
                            Spacer(minLength: 4)
                            deleteSectionActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            deleteSectionLabel
                            HStack {
                                Spacer()
                                deleteSectionActions
                            }
                        }
                    }
                    .zeyingAlignedGroupedSectionHeader()
                    .textCase(nil)
                }
            }

            if !albumItems.isEmpty {
                Section {
                    ForEach(albumItems, id: \.assetIdentifier) { assignment in
                        albumAssignmentRow(
                            assignment,
                            showsSeparator: assignment.assetIdentifier != albumItems.last?.assetIdentifier
                        )
                    }
                } header: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            albumSectionLabel
                            Spacer(minLength: 4)
                            albumSectionActions
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            albumSectionLabel
                            HStack {
                                Spacer()
                                albumSectionActions
                            }
                        }
                    }
                    .zeyingAlignedGroupedSectionHeader()
                    .textCase(nil)
                }
            }

            if !unavailableAlbumItems.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "有 \(unavailableAlbumItems.count) 项相簿整理记录暂时无法访问。"))
                            .font(.subheadline.weight(.medium))
                        Text(library.authorizationStatus != .authorized
                             ? String(localized: "它们可能属于尚未授权给择影的项目；调整可访问范围后会重新出现。")
                             : String(localized: "它们可能对应已被删除或移出当前图库的项目。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if library.authorizationStatus == .limited {
                            Button(String(localized: "管理可访问照片")) {
                                ZeyingLimitedLibraryAccess.present(using: library)
                            }
                            .buttonStyle(ZeyingGlassButtonStyle())
                        } else if library.authorizationStatus != .authorized {
                            Button(String(localized: "管理照片访问权限")) {
                                openPhotoSettings()
                            }
                            .buttonStyle(ZeyingGlassButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color(uiColor: .secondarySystemBackground))
                } header: {
                    Label(String(localized: "不可访问的相簿整理（\(unavailableAlbumItems.count)）"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .zeyingAlignedGroupedSectionHeader()
                }
            }
        }
    }

    private var deleteSectionLabel: some View {
        Label(String(localized: "待删除"), systemImage: "trash.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var favoriteSectionLabel: some View {
        Label(String(localized: "待收藏"), systemImage: "star.fill")
            .foregroundStyle(.yellow)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var favoriteSectionActions: some View {
        HStack(spacing: 6) {
            sectionAction(
                String(localized: "全部取消收藏"),
                accessibilityLabel: String(localized: "取消所有待收藏项目")
            ) {
                cancelPendingFavorites(favoriteIDs)
            }
            sectionAction(
                String(localized: "收藏"),
                accessibilityLabel: String(localized: "确认收藏 \(favoriteIDs.count) 项")
            ) {
                requestedFavoriteIDs = favoriteIDs
                showingFavoriteConfirmation = true
            }
        }
    }

    private var albumSectionLabel: some View {
        Label(String(localized: "待整理相簿"), systemImage: "rectangle.stack.badge.plus")
            .foregroundStyle(.blue)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var albumSectionActions: some View {
        HStack(spacing: 6) {
            sectionAction(
                String(localized: "全部不加入"),
                accessibilityLabel: String(localized: "取消所有待加入相簿项目")
            ) {
                cancelPendingAlbumAssignments(albumAssignments.assignments.map(\.assetIdentifier))
            }
            sectionAction(
                String(localized: "加入相簿"),
                accessibilityLabel: String(localized: "确认加入相簿，\(albumItems.count) 项")
            ) {
                requestedAlbumIDs = albumItems.map(\.assetIdentifier)
                showingAlbumConfirmation = true
            }
        }
    }

    private var deleteSectionActions: some View {
        HStack(spacing: 6) {
            sectionAction(
                String(localized: "恢复全部"),
                accessibilityLabel: String(localized: "恢复所有待删除项目")
            ) {
                recoverDeletions(deleteIDs)
            }
            sectionAction(
                String(localized: "删除全部"),
                accessibilityLabel: String(localized: "确认删除 \(deleteIDs.count) 项")
            ) {
                requestedDeletionIDs = deleteIDs
                showingDeleteConfirmation = true
            }
        }
    }

    private func sectionAction(
        _ title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.blue)
        .disabled(isCommitting)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func summaryAssetRow(
        identifier: String,
        decision: ReviewDecision,
        showsSeparator: Bool
    ) -> some View {
        if let asset = library.asset(with: identifier) {
            let isDeletion = decision == .delete
            if isDeletion {
                HStack(spacing: 10) {
                    Button {
                        previewSelection = SummaryPreviewSelection(
                            assetIdentifier: identifier,
                            assetIdentifiers: deleteIDs,
                            actionMode: .delete
                        )
                    } label: {
                        summaryAssetRowContent(asset: asset, isDeletion: true, trailingTitle: nil)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .disabled(isCommitting)
                    .accessibilityLabel(String(localized: "预览待删除\(pendingAssetDescription(asset))"))

                    summaryRowAction(String(localized: "恢复"), labelWidth: regularRowActionLabelWidth) {
                        recoverDeletions([identifier])
                    }
                    .frame(width: rowActionColumnWidth)
                    .accessibilityLabel(String(localized: "恢复待删除\(pendingAssetDescription(asset))"))
                }
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(showsSeparator ? .visible : .hidden, edges: .bottom)
                .listRowBackground(Color(uiColor: .secondarySystemBackground))
            } else {
                HStack(alignment: .center, spacing: 10) {
                    Button {
                        previewSelection = SummaryPreviewSelection(
                            assetIdentifier: identifier,
                            assetIdentifiers: favoriteIDs,
                            actionMode: .favorite
                        )
                    } label: {
                        summaryAssetRowContent(asset: asset, isDeletion: false, trailingTitle: nil)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .disabled(isCommitting)

                    pendingRowActions(cancelTitle: String(localized: "取消收藏")) {
                        editSelection = SummaryEditSelection(id: identifier)
                    } onCancel: {
                        cancelPendingFavorites([identifier])
                    }
                }
                .listRowSeparator(.hidden, edges: .top)
                .listRowSeparator(showsSeparator ? .visible : .hidden, edges: .bottom)
                .listRowBackground(Color(uiColor: .secondarySystemBackground))
            }
        }
    }

    private func summaryAssetRowContent(asset: PHAsset, isDeletion: Bool, trailingTitle: String?) -> some View {
        HStack(spacing: 12) {
            AssetImageView(
                asset: asset,
                library: library,
                contentMode: .fill,
                allowNetwork: false
            )
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(asset.creationDate?.zeyingShortDate ?? String(localized: "日期未知"))
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    Image(systemName: isDeletion ? "trash" : "star")
                        .foregroundStyle(isDeletion ? .red : .yellow)
                    Text(isDeletion
                         ? (LivePhotoConversionManager.shared.conversion(for: asset.localIdentifier) == nil
                            ? String(localized: "待删除")
                            : String(localized: "原实况照片 · 待删除"))
                         : String(localized: "待收藏"))
                        .foregroundStyle(isDeletion ? Color(uiColor: .secondaryLabel) : .yellow)
                }
                .font(.caption)
            }
            Spacer()
            if let trailingTitle {
                Text(trailingTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isDeletion ? Color.blue : Color.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func pendingAssetDescription(_ asset: PHAsset) -> String {
        let type = asset.mediaType == .video ? String(localized: "视频")
            : asset.mediaSubtypes.contains(.photoLive) ? String(localized: "实况照片") : String(localized: "照片")
        let date = asset.creationDate?.zeyingDetailedDate ?? String(localized: "日期未知")
        let position = (deleteIDs.firstIndex(of: asset.localIdentifier) ?? 0) + 1
        return String(localized: "\(type)，\(date)，第 \(position) 项")
    }

    private func recoverDeletions(_ identifiers: [String]) {
        guard reviews.recoverPendingDeletions(identifiers) else {
            operationError = reviews.errorMessage ?? String(localized: "无法恢复待删除项目。")
            showingError = true
            return
        }
    }

    private var rowActionColumnWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 148 : 100
    }

    private var regularRowActionLabelWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 130 : 80
    }

    private func pendingRowActions(
        cancelTitle: String,
        onEdit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        let enlarged = dynamicTypeSize.isAccessibilitySize
        let labelWidth: CGFloat = enlarged ? 130 : 84
        return VStack(alignment: .center, spacing: 4) {
            summaryRowAction(String(localized: "修改"), labelWidth: labelWidth,
                             compact: !enlarged, action: onEdit)
            summaryRowAction(cancelTitle, labelWidth: labelWidth,
                             compact: !enlarged, action: onCancel)
        }
        .frame(width: rowActionColumnWidth)
    }

    private func summaryRowAction(
        _ title: String,
        labelWidth: CGFloat? = nil,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: labelWidth == nil, vertical: false)
                .frame(width: labelWidth, height: compact ? 16 : nil)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(compact ? .mini : .small)
        .tint(.gray)
        .disabled(isCommitting)
    }

    private func cancelPendingFavorites(_ identifiers: [String]) {
        guard reviews.cancelPendingFavorites(identifiers) else {
            operationError = reviews.errorMessage ?? String(localized: "无法取消待收藏项目。")
            showingError = true
            return
        }
    }

    private func cancelPendingAlbumAssignments(_ identifiers: [String]) {
        let selected = Set(identifiers)
        let requested = albumAssignments.assignments.filter { selected.contains($0.assetIdentifier) }
        guard !requested.isEmpty else { return }
        for assignment in requested where reviews.decision(for: assignment.assetIdentifier) != .keep {
            guard reviews.decide(.keep, for: assignment.assetIdentifier) else {
                operationError = reviews.errorMessage ?? String(localized: "无法保留照片。")
                showingError = true
                return
            }
        }
        guard albumAssignments.removeApplied(requested.map(\.assetIdentifier)) else {
            operationError = albumAssignments.errorMessage ?? String(localized: "无法取消相簿整理。")
            showingError = true
            return
        }
    }

    @ViewBuilder
    private func albumAssignmentRow(
        _ assignment: PendingAlbumAssignment,
        showsSeparator: Bool
    ) -> some View {
        if let asset = library.asset(with: assignment.assetIdentifier) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    previewSelection = SummaryPreviewSelection(
                        assetIdentifier: assignment.assetIdentifier,
                        assetIdentifiers: albumItems.map(\.assetIdentifier),
                        actionMode: .album
                    )
                } label: {
                    albumAssignmentRowContent(asset: asset, assignment: assignment)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .disabled(isCommitting)

                pendingRowActions(cancelTitle: String(localized: "不加入相簿")) {
                    editSelection = SummaryEditSelection(id: assignment.assetIdentifier)
                } onCancel: {
                    cancelPendingAlbumAssignments([assignment.assetIdentifier])
                }
            }
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparator(showsSeparator ? .visible : .hidden, edges: .bottom)
            .listRowBackground(Color(uiColor: .secondarySystemBackground))
        }
    }

    private func albumAssignmentRowContent(asset: PHAsset, assignment: PendingAlbumAssignment) -> some View {
        HStack(spacing: 12) {
            AssetImageView(asset: asset, library: library, contentMode: .fill, allowNetwork: false)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.creationDate?.zeyingShortDate ?? String(localized: "日期未知"))
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    Image(systemName: assignment.isNewAlbum ? "plus.rectangle" : "rectangle.stack")
                        .font(.system(size: albumRowIconSize))
                    Text(assignment.isNewAlbum ? String(localized: "新建：\(assignment.albumTitle)") : assignment.albumTitle)
                }
                .font(.caption)
                .foregroundStyle(.blue)
                .accessibilityElement(children: .combine)
            }
            Spacer()
        }
    }

    private func commitFavorites(_ identifiers: [String]) async {
        let requested = Array(Set(identifiers).intersection(favoriteIDs)).sorted()
        guard !requested.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }

        do {
            let succeeded = try await library.favorite(requested)
            guard reviews.markFavorited(succeeded) else {
                operationError = reviews.errorMessage ?? String(localized: "无法保存收藏进度。")
                showingError = true
                return
            }
        } catch {
            operationError = PhotosFailureMessage.message(for: error)
            showingError = true
        }
    }

    private func commitAlbumAssignments(_ identifiers: [String]) async {
        let selected = Set(identifiers)
        let requested = albumItems.filter { selected.contains($0.assetIdentifier) }
        guard !requested.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }

        do {
            let result = try await albumService.apply(
                requested,
                onAlbumCreationIntent: { title, assetIdentifiers, existingAlbumIdentifiers in
                    albumAssignments.stageAlbumCreation(
                        title: title,
                        for: assetIdentifiers,
                        existingAlbumIdentifiers: existingAlbumIdentifiers
                    )
                },
                onCreatedAlbum: { identifier, title, assetIdentifiers in
                    let saved = albumAssignments.resolveNewAlbum(
                        identifier: identifier,
                        title: title,
                        for: assetIdentifiers
                    )
                    if saved {
                        for _ in assetIdentifiers { albumService.recordSelection(of: identifier) }
                    }
                    return saved
                }
            )
            guard albumAssignments.removeApplied(result.appliedIdentifiers) else {
                operationError = albumAssignments.errorMessage ?? String(localized: "无法清除已完成的相簿整理记录。")
                showingError = true
                return
            }
            if !result.failedIdentifiers.isEmpty || result.errorMessage != nil {
                let detail = result.errorMessage ?? String(localized: "部分项目未能加入相簿。")
                operationError = String(localized: "已完成 \(result.appliedIdentifiers.count) 项，仍有 \(result.failedIdentifiers.count) 项待处理。\n\(detail)")
                showingError = true
            }
            await library.refresh()
        } catch {
            operationError = PhotosFailureMessage.message(for: error)
            showingError = true
        }
    }

    private func commitDeletes(_ identifiers: [String]) async {
        let pendingIDs = Set(deleteIDs)
        let requestedIDs = Array(Set(identifiers).intersection(pendingIDs)).sorted()
        guard !requestedIDs.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }

        let statByIdentifier = Dictionary(
            uniqueKeysWithValues: requestedIDs.compactMap { identifier -> (String, DeletedAssetStat)? in
                guard let asset = library.asset(with: identifier) else { return nil }
                return (
                    identifier,
                    DeletedAssetStat(
                        identifier: identifier,
                        isVideo: asset.mediaType == .video,
                        knownBytes: sizes.knownSize(for: asset)
                    )
                )
            }
        )

        do {
            let conversions = LivePhotoConversionManager.shared
            try conversions.verifyStagedOriginals(in: requestedIDs, reviews: reviews)
            let conversionIDs = Set(requestedIDs.filter { conversions.conversion(for: $0) != nil })
            // PhotoLibraryService preserves the PhotoKit error so cancelling
            // the system confirmation leaves these local todos visible.
            let succeeded = try await library.delete(requestedIDs)
            var cleanedIDs: [String] = []
            var conversionErrors: [String] = []
            for identifier in succeeded {
                guard conversionIDs.contains(identifier) else {
                    cleanedIDs.append(identifier)
                    continue
                }
                do {
                    try conversions.finishStagedOriginalDeletion(
                        sourceIdentifier: identifier,
                        reviews: reviews,
                        albumAssignments: albumAssignments
                    )
                    cleanedIDs.append(identifier)
                } catch {
                    conversionErrors.append(error.localizedDescription)
                }
            }
            let statisticsSaved = reviews.recordCommittedDeletion(
                succeeded.filter { !conversionIDs.contains($0) }
                    .compactMap { statByIdentifier[$0] }
            )
            let statisticsError = statisticsSaved ? nil : reviews.errorMessage
            guard reviews.removeDeleted(cleanedIDs) else {
                operationError = [statisticsError, reviews.errorMessage]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                if operationError?.isEmpty == true { operationError = String(localized: "无法保存删除进度。") }
                showingError = true
                return
            }
            guard albumAssignments.removeApplied(cleanedIDs) else {
                operationError = albumAssignments.errorMessage ?? String(localized: "项目已删除，但相簿整理记录未能清除。")
                showingError = true
                return
            }
            let errors = ([statisticsError].compactMap { $0 } + conversionErrors)
            if !errors.isEmpty {
                operationError = errors.joined(separator: "\n")
                showingError = true
            }
        } catch {
            operationError = isPhotoLibraryUserCancelled(error)
                ? String(localized: "已取消删除，待删除清单已保留。")
                : PhotosFailureMessage.message(for: error)
            showingError = true
        }
    }

    private func openPhotoSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func isPhotoLibraryUserCancelled(_ error: Error) -> Bool {
        if let photosError = error as? PHPhotosError,
           photosError.code == .userCancelled {
            return true
        }
        return false
    }
}

private enum SummaryPreviewActionMode: Equatable {
    case delete
    case favorite
    case album

    var defaultTitle: String {
        switch self {
        case .delete: String(localized: "待删除")
        case .favorite: String(localized: "待收藏")
        case .album: String(localized: "待整理相簿")
        }
    }
}

private struct SummaryPreviewSelection: Identifiable {
    let assetIdentifier: String
    let assetIdentifiers: [String]
    let actionMode: SummaryPreviewActionMode
    var id: String { assetIdentifier }
}

private struct UnavailableSummaryPreviewSheet: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                String(localized: "项目暂时无法访问"),
                systemImage: "photo.on.rectangle.angled",
                description: Text(String(localized: "这条本地待办会保留；调整照片访问权限后可以再次查看。"))
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SummaryAssetPreviewSheet: View {
    let assetIDs: [String]
    let library: PhotoLibraryService
    let albumAssignments: PendingAlbumAssignmentStore
    let actionMode: SummaryPreviewActionMode
    let onRecover: (String) -> Void
    let onDelete: (String) -> Void
    let onEdit: (String) -> Void
    let onCancelPending: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    @State private var scale: CGFloat = 1
    @State private var pinchStartScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panStartOffset: CGSize = .zero
    @State private var videoSoundEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var usesExpandedPreviewLayout: Bool {
        (horizontalSizeClass == .regular || verticalSizeClass == .compact) &&
            !dynamicTypeSize.isAccessibilitySize
    }

    private var previewLayout: AnyLayout {
        usesExpandedPreviewLayout
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
    }

    private var previewTitle: String {
        if actionMode == .album,
           let albumTitle = albumAssignments.assignment(for: selectedID)?.albumTitle,
           !albumTitle.isEmpty {
            return albumTitle
        }
        return actionMode.defaultTitle
    }

    init(assetIDs: [String], initialID: String, library: PhotoLibraryService,
         albumAssignments: PendingAlbumAssignmentStore,
         actionMode: SummaryPreviewActionMode,
         onRecover: @escaping (String) -> Void,
         onDelete: @escaping (String) -> Void,
         onEdit: @escaping (String) -> Void,
         onCancelPending: @escaping (String) -> Void) {
        self.assetIDs = assetIDs
        self.library = library
        self.albumAssignments = albumAssignments
        self.actionMode = actionMode
        self.onRecover = onRecover
        self.onDelete = onDelete
        self.onEdit = onEdit
        self.onCancelPending = onCancelPending
        _selectedID = State(initialValue: initialID)
    }

    var body: some View {
        NavigationStack {
            previewLayout {
                GeometryReader { proxy in
                    ZStack {
                        Color.black.ignoresSafeArea()
                        if let asset = library.asset(with: selectedID), asset.mediaType == .video {
                            AssetPreviewView(
                                asset: asset,
                                library: library,
                                videoSoundEnabled: $videoSoundEnabled,
                                initialPreview: library.cachedQuickPreview(for: asset),
                                autoplayVideo: true,
                                cornerRadius: 0
                            )
                            .id(asset.localIdentifier)
                        } else if let asset = library.asset(with: selectedID) {
                            AssetImageView(
                                asset: asset,
                                library: library,
                                contentMode: .fit,
                                allowNetwork: settings.iCloudAutoDownloadEnabled,
                                targetSize: CGSize(width: 1_500, height: 1_500),
                                requiresFullQuality: true,
                                allowCloudThumbnail: true
                            )
                            .id(asset.localIdentifier)
                            .scaleEffect(scale)
                            .offset(offset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .simultaneousGesture(magnificationGesture)
                            .simultaneousGesture(panGesture(in: proxy.size))
                            .onTapGesture(count: 2) {
                                setScale(scale > 1.01 ? 1 : 2)
                            }
                            .accessibilityValue(String(localized: "缩放 \(Int(scale * 100))%"))
                            .accessibilityAction(named: String(localized: "放大")) { setScale(min(scale + 1, 4)) }
                            .accessibilityAction(named: String(localized: "缩小")) { setScale(max(scale - 1, 1)) }
                            .accessibilityAction(named: String(localized: "恢复原始大小")) { setScale(1) }
                        }

                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 25).onEnded { value in
                            guard scale <= 1.01,
                                  abs(value.translation.width) >= 70,
                                  abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                            movePreview(value.translation.width < 0 ? 1 : -1)
                        }
                    )
                }
                VStack(spacing: 14) {
                    if actionMode == .delete {
                        Button { onRecover(selectedID) } label: {
                            Label(String(localized: "恢复"), systemImage: "arrow.uturn.backward")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .tint(.white)

                        Button(role: .destructive) { onDelete(selectedID) } label: {
                            Label(String(localized: "删除"), systemImage: "trash")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .tint(.red)
                    } else {
                        Button { onEdit(selectedID) } label: {
                            Label(String(localized: "修改"), systemImage: "pencil")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .tint(.white)

                        Button { onCancelPending(selectedID) } label: {
                            Label(
                                actionMode == .favorite
                                    ? String(localized: "取消收藏")
                                    : String(localized: "不加入相簿"),
                                systemImage: actionMode == .favorite ? "star.slash" : "rectangle.stack.badge.minus"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .tint(.white)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(.black)
                .frame(minWidth: usesExpandedPreviewLayout ? 210 : nil,
                       idealWidth: usesExpandedPreviewLayout ? 250 : nil,
                       maxWidth: usesExpandedPreviewLayout ? 290 : .infinity)
                .frame(maxHeight: usesExpandedPreviewLayout ? .infinity : nil, alignment: .center)
            }
            .background(.black)
            .navigationTitle(previewTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "关闭")) { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .onChange(of: selectedID) { _, _ in
                scale = 1
                pinchStartScale = 1
                offset = .zero
                panStartOffset = .zero
            }
            .task(id: selectedID, priority: .utility) {
                await prefetchAdjacentPreviews()
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func movePreview(_ direction: Int) {
        guard let current = assetIDs.firstIndex(of: selectedID) else { return }
        var next = current + direction
        while assetIDs.indices.contains(next) {
            let identifier = assetIDs[next]
            if library.asset(with: identifier) != nil {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    selectedID = identifier
                }
                if settings.hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
                return
            }
            next += direction
        }
    }

    private func prefetchAdjacentPreviews() async {
        guard let current = assetIDs.firstIndex(of: selectedID) else { return }
        for next in [current + 1, current - 1] where assetIDs.indices.contains(next) {
            guard !Task.isCancelled else { return }
            if let asset = library.asset(with: assetIDs[next]), asset.mediaType == .image {
                _ = await library.prepareReviewPreview(for: asset)
            }
        }
    }

    private func setScale(_ proposed: CGFloat) {
        let next = min(max(proposed, 1), 4)
        let update = {
            scale = next
            pinchStartScale = next
            if next <= 1.01 {
                offset = .zero
                panStartOffset = .zero
            } else {
                panStartOffset = offset
            }
        }
        if reduceMotion {
            update()
        } else {
            withAnimation(.snappy, update)
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(pinchStartScale * value, 1), 4)
            }
            .onEnded { _ in
                pinchStartScale = scale
                if scale <= 1.01 {
                    scale = 1
                    offset = .zero
                    panStartOffset = .zero
                }
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = clampedOffset(
                    CGSize(
                        width: panStartOffset.width + value.translation.width,
                        height: panStartOffset.height + value.translation.height
                    ),
                    in: size
                )
            }
            .onEnded { _ in
                panStartOffset = offset
            }
    }

    private func clampedOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let horizontalLimit = max(0, (scale - 1) * size.width / 2)
        let verticalLimit = max(0, (scale - 1) * size.height / 2)
        return CGSize(
            width: min(max(proposed.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposed.height, -verticalLimit), verticalLimit)
        )
    }
}
