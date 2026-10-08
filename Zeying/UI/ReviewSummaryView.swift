import Photos
import SwiftUI
import UIKit

struct ReviewSummaryView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore

    @State private var showingFavoriteConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var requestedDeletionIDs: [String] = []
    @State private var deleteAfterPreviewDismissal: String?
    @State private var isCommitting = false
    @State private var showingError = false
    @State private var showingUnavailableCleanupConfirmation = false
    @State private var showingAlbumConfirmation = false
    @State private var operationError: String?
    @State private var previewSelection: SummaryPreviewSelection?

    private var favoriteIDs: [String] {
        reviews.pendingFavoriteIdentifiers
            .filter { library.asset(with: $0) != nil }
    }

    private var deleteIDs: [String] {
        reviews.identifiers(with: .delete)
            .filter { library.asset(with: $0) != nil }
    }

    private var unavailableIDs: [String] {
        reviews.unavailableIdentifiers(among: Set(library.assets.map(\.localIdentifier)))
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
            ZeyingRootPageTitle(title: String(localized: "清单"))

            Group {
                if !library.hasLoaded,
                   library.authorizationStatus == .authorized || library.authorizationStatus == .limited {
                    ProgressView(String(localized: "正在读取照片…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if favoriteIDs.isEmpty && deleteIDs.isEmpty && albumItems.isEmpty &&
                            unavailableIDs.isEmpty && unavailableAlbumItems.isEmpty &&
                            LivePhotoConversionManager.shared.pendingConversions.isEmpty &&
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
        .toolbar(.hidden, for: .navigationBar)
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
            Button(String(localized: "确认收藏 \(favoriteIDs.count) 项")) {
                Task { await commitFavorites() }
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
                Task { await commitAlbumAssignments() }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "确认后，所选项目会加入对应的个人相簿。"))
        }
        .confirmationDialog(
            String(localized: "清理不可访问的本地记录？"),
            isPresented: $showingUnavailableCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "只清理本地记录"), role: .destructive) {
                Task { await cleanupUnavailableRecords() }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "只会删除择影保存的处理记录，不会修改系统照片。"))
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
            }
        }) { selection in
            if let asset = library.asset(with: selection.assetIdentifier) {
                SummaryAssetPreviewSheet(assetIDs: selection.assetIdentifiers, initialID: asset.localIdentifier, library: library) { identifier in
                    recoverDeletions([identifier])
                    previewSelection = nil
                } onDelete: { identifier in
                    deleteAfterPreviewDismissal = identifier
                    previewSelection = nil
                }
            } else {
                UnavailableSummaryPreviewSheet()
            }
        }
    }

    private var summaryList: some View {
        List {
            PendingLiveConversionsSection(
                library: library,
                reviews: reviews,
                albumAssignments: albumAssignments
            )

            if !favoriteIDs.isEmpty {
                Section {
                    ForEach(favoriteIDs, id: \.self) { identifier in
                        summaryAssetRow(identifier: identifier, decision: .keep)
                    }
                } header: {
                    HStack {
                        Label(String(localized: "待收藏"), systemImage: "star.fill")
                        Spacer()
                        sectionAction(
                            String(localized: "收藏"),
                            accessibilityLabel: String(localized: "确认收藏 \(favoriteIDs.count) 项")
                        ) {
                            showingFavoriteConfirmation = true
                        }
                    }
                    .zeyingAlignedGroupedSectionHeader()
                    .textCase(nil)
                } footer: {
                    Text(String(localized: "收藏会视为保留，不会删除这些项目。"))
                }
            }

            if !deleteIDs.isEmpty {
                Section {
                    ForEach(deleteIDs, id: \.self) { identifier in
                        summaryAssetRow(identifier: identifier, decision: .delete)
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
                        albumAssignmentRow(assignment)
                    }
                } header: {
                    HStack {
                        Label(String(localized: "待整理相簿"), systemImage: "rectangle.stack.badge.plus")
                        Spacer()
                        sectionAction(
                            String(localized: "加入相簿"),
                            accessibilityLabel: String(localized: "确认加入相簿，\(albumItems.count) 项")
                        ) {
                            showingAlbumConfirmation = true
                        }
                    }
                    .zeyingAlignedGroupedSectionHeader()
                    .textCase(nil)
                } footer: {
                    Text(String(localized: "选择相簿会视为保留。确认后才会写入系统照片相簿。"))
                }
            }

            if !unavailableIDs.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "有 \(unavailableIDs.count) 项本地处理记录当前无法在照片图库中找到。"))
                            .font(.subheadline.weight(.medium))
                        Text(library.authorizationStatus != .authorized
                             ? String(localized: "它们可能属于尚未授权给择影的照片。调整可访问范围后，记录可能重新出现。")
                             : String(localized: "它们可能对应已被删除或移出当前图库的照片。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if library.authorizationStatus == .authorized {
                            Button(String(localized: "清理本地记录")) {
                                showingUnavailableCleanupConfirmation = true
                            }
                            .buttonStyle(ZeyingGlassButtonStyle(tint: .red))
                        } else if library.authorizationStatus == .limited {
                            Button(String(localized: "管理可访问照片")) {
                                ZeyingLimitedLibraryAccess.present(using: library)
                            }
                            .buttonStyle(ZeyingGlassButtonStyle())
                        } else {
                            Button(String(localized: "管理照片访问权限")) {
                                openPhotoSettings()
                            }
                            .buttonStyle(ZeyingGlassButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                } header: {
                    Label(String(localized: "不可访问（\(unavailableIDs.count)）"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .zeyingAlignedGroupedSectionHeader()
                } footer: {
                    Text(String(localized: "这些记录会保留，直到你明确调整权限或清理本地记录。"))
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
                    .listRowBackground(Color.clear)
                } header: {
                    Label(String(localized: "不可访问的相簿整理（\(unavailableAlbumItems.count)）"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .zeyingAlignedGroupedSectionHeader()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable {
            await library.refresh()
        }
    }

    private var deleteSectionLabel: some View {
        Label(String(localized: "待删除"), systemImage: "trash.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: true, vertical: false)
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
    private func summaryAssetRow(identifier: String, decision: ReviewDecision) -> some View {
        if let asset = library.asset(with: identifier) {
            let isDeletion = decision == .delete
            if isDeletion {
                HStack(spacing: 10) {
                    Button {
                        previewSelection = SummaryPreviewSelection(assetIdentifier: identifier, assetIdentifiers: deleteIDs)
                    } label: {
                        summaryAssetRowContent(asset: asset, isDeletion: true, trailingTitle: nil)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .disabled(isCommitting)
                    .accessibilityLabel(String(localized: "查看这个待删除项目的预览"))

                    Button {
                        recoverDeletions([identifier])
                    } label: {
                        Text(String(localized: "恢复"))
                            .font(.caption.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.blue)
                    .disabled(isCommitting)
                    .accessibilityLabel(asset.mediaType == .video
                        ? String(localized: "恢复这段待删除视频")
                        : String(localized: "恢复这张待删除照片"))
                }
            } else {
                NavigationLink {
                    ReviewQueueView(
                        assetIDs: [identifier],
                        library: library,
                        reviews: reviews,
                        sizes: sizes,
                        albumService: albumService,
                        albumAssignments: albumAssignments
                    )
                } label: {
                    summaryAssetRowContent(asset: asset, isDeletion: false, trailingTitle: String(localized: "修改"))
                }
                .accessibilityLabel(String(localized: "编辑待收藏项目"))
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
                        .foregroundStyle(isDeletion ? .red : .orange)
                    Text(isDeletion ? String(localized: "待删除") : String(localized: "待收藏"))
                        .foregroundStyle(.secondary)
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

    private func recoverDeletions(_ identifiers: [String]) {
        guard reviews.recoverPendingDeletions(identifiers) else {
            operationError = reviews.errorMessage ?? String(localized: "无法恢复待删除项目。")
            showingError = true
            return
        }
    }

    @ViewBuilder
    private func albumAssignmentRow(_ assignment: PendingAlbumAssignment) -> some View {
        if let asset = library.asset(with: assignment.assetIdentifier) {
            NavigationLink {
                ReviewQueueView(
                    assetIDs: [assignment.assetIdentifier],
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments
                )
            } label: {
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
                        Label(
                            assignment.isNewAlbum ? String(localized: "新建：\(assignment.albumTitle)") : assignment.albumTitle,
                            systemImage: assignment.isNewAlbum ? "plus.rectangle" : "rectangle.stack"
                        )
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }
                    Spacer()
                    Text(String(localized: "修改"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    _ = albumAssignments.remove(assetIdentifier: assignment.assetIdentifier)
                } label: {
                    Label(String(localized: "移除"), systemImage: "trash")
                }
            }
            .accessibilityLabel(String(localized: "编辑加入相簿 \(assignment.albumTitle) 的项目"))
        }
    }

    private func commitFavorites() async {
        guard !favoriteIDs.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }

        do {
            let succeeded = try await library.favorite(favoriteIDs)
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

    private func commitAlbumAssignments() async {
        let requested = albumItems
        guard !requested.isEmpty else { return }
        let existingAlbumByAsset = Dictionary(uniqueKeysWithValues: requested.compactMap { assignment in
            assignment.albumIdentifier.map { (assignment.assetIdentifier, $0) }
        })
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
                    if saved { albumService.recordSelection(of: identifier) }
                    return saved
                }
            )
            guard albumAssignments.removeApplied(result.appliedIdentifiers) else {
                operationError = albumAssignments.errorMessage ?? String(localized: "无法清除已完成的相簿整理记录。")
                showingError = true
                return
            }
            for assetIdentifier in result.appliedIdentifiers {
                if let albumIdentifier = existingAlbumByAsset[assetIdentifier] {
                    albumService.recordSelection(of: albumIdentifier)
                }
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
            // PhotoLibraryService preserves the PhotoKit error so cancelling
            // the system confirmation leaves these local todos visible.
            let succeeded = try await library.delete(requestedIDs)
            let statisticsSaved = reviews.recordCommittedDeletion(
                succeeded.compactMap { statByIdentifier[$0] }
            )
            let statisticsError = statisticsSaved ? nil : reviews.errorMessage
            guard reviews.removeDeleted(succeeded) else {
                operationError = [statisticsError, reviews.errorMessage]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                if operationError?.isEmpty == true { operationError = String(localized: "无法保存删除进度。") }
                showingError = true
                return
            }
            guard albumAssignments.removeApplied(succeeded) else {
                operationError = albumAssignments.errorMessage ?? String(localized: "项目已删除，但相簿整理记录未能清除。")
                showingError = true
                return
            }
            if let statisticsError {
                operationError = statisticsError
                showingError = true
            }
        } catch {
            operationError = isPhotoLibraryUserCancelled(error)
                ? String(localized: "已取消删除，待删除清单已保留。")
                : PhotosFailureMessage.message(for: error)
            showingError = true
        }
    }

    private func cleanupUnavailableRecords() async {
        guard !unavailableIDs.isEmpty else { return }
        isCommitting = true
        defer { isCommitting = false }

        guard reviews.removeDeleted(unavailableIDs) else {
            operationError = reviews.errorMessage ?? String(localized: "无法清理本地处理记录。")
            showingError = true
            return
        }
        guard albumAssignments.removeApplied(unavailableIDs) else {
            operationError = albumAssignments.errorMessage ?? String(localized: "无法清理相簿整理记录。")
            showingError = true
            return
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

private struct SummaryPreviewSelection: Identifiable {
    let assetIdentifier: String
    let assetIdentifiers: [String]
    var id: String { assetIdentifier }
}

private struct UnavailableSummaryPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                String(localized: "项目暂时无法访问"),
                systemImage: "photo.on.rectangle.angled",
                description: Text(String(localized: "这条本地待办会保留；调整照片访问权限后可以再次查看。"))
            )
            .navigationTitle(String(localized: "媒体预览"))
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
    let onRecover: (String) -> Void
    let onDelete: (String) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    @State private var scale: CGFloat = 1
    @State private var pinchStartScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panStartOffset: CGSize = .zero
    @State private var videoSoundEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(assetIDs: [String], initialID: String, library: PhotoLibraryService,
         onRecover: @escaping (String) -> Void, onDelete: @escaping (String) -> Void) {
        self.assetIDs = assetIDs
        self.library = library
        self.onRecover = onRecover
        self.onDelete = onDelete
        _selectedID = State(initialValue: initialID)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let asset = library.asset(with: selectedID), asset.mediaType == .video {
                        AssetPreviewView(
                            asset: asset,
                            library: library,
                            videoSoundEnabled: $videoSoundEnabled,
                            initialPreview: library.cachedQuickPreview(for: asset),
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
                            requiresFullQuality: true
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
                    }

                    if let asset = library.asset(with: selectedID), asset.mediaType == .video {
                        VStack {
                            Spacer()
                            Text(String(localized: "点按播放后加载视频内容；关闭可返回清单。"))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.45), in: Capsule())
                                .padding(.bottom, 18)
                        }
                        .allowsHitTesting(false)
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 14) {
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
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(.black)
            }
            .navigationTitle(String(localized: "媒体预览"))
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
                videoSoundEnabled = false
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
