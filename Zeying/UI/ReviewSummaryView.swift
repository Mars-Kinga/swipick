import Photos
import SwiftUI

struct ReviewSummaryView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore

    @State private var showingFavoriteConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var isCommitting = false
    @State private var showingError = false
    @State private var showingUnavailableCleanupConfirmation = false
    @State private var showingAlbumConfirmation = false
    @State private var operationError: String?

    private var favoriteIDs: [String] {
        reviews.pendingFavoriteIdentifiers
            .filter { library.asset(with: $0) != nil }
    }

    private var deleteIDs: [String] {
        reviews.identifiers(with: .delete)
            .filter { library.asset(with: $0) != nil }
    }

    private var unavailableIDs: [String] {
        guard library.hasLoaded else { return [] }
        return reviews.unavailableIdentifiers(
            among: Set(library.assets.map(\.localIdentifier))
        ).filter { identifier in
            library.asset(with: identifier) == nil &&
                (reviews.decision(for: identifier) == .delete || reviews.isPendingFavorite(identifier))
        }
    }

    private var albumItems: [PendingAlbumAssignment] {
        albumAssignments.assignments.filter { library.asset(with: $0.assetIdentifier) != nil }
    }

    private var unavailableAlbumItems: [PendingAlbumAssignment] {
        guard library.hasLoaded else { return [] }
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
        .confirmationDialog(
            String(localized: "确认收藏这些照片？"),
            isPresented: $showingFavoriteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "确认收藏 \(favoriteIDs.count) 张")) {
                Task { await commitFavorites() }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "照片会同步到系统照片的“个人收藏”中，并从待收藏清单移除。"))
        }
        .alert(
            String(localized: "确认删除这些照片？"),
            isPresented: $showingDeleteConfirmation
        ) {
            Button(String(localized: "删除 \(deleteIDs.count) 张"), role: .destructive) {
                Task { await commitDeletes() }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "照片会从系统照片图库移除，并按系统设置进入“最近删除”。"))
        }
        .confirmationDialog(
            String(localized: "确认整理这些照片？"),
            isPresented: $showingAlbumConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "整理 \(albumItems.count) 张照片")) {
                Task { await commitAlbumAssignments() }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "照片会加入所选个人相簿；新相簿会在确认时创建。"))
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
                            accessibilityLabel: String(localized: "确认收藏 \(favoriteIDs.count) 张")
                        ) {
                            showingFavoriteConfirmation = true
                        }
                    }
                    .zeyingAlignedGroupedSectionHeader()
                    .textCase(nil)
                } footer: {
                    Text(String(localized: "收藏会视为保留，不会删除照片。"))
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
                } footer: {
                    Text(String(localized: "提交到系统照片时，iOS 还会显示删除确认。"))
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
                            String(localized: "整理"),
                            accessibilityLabel: String(localized: "确认整理 \(albumItems.count) 张照片")
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
                        Text(String(localized: "有 \(unavailableIDs.count) 条本地处理记录当前无法在照片图库中找到。"))
                            .font(.subheadline.weight(.medium))
                        Text(library.authorizationStatus == .limited
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
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                } header: {
                    Label(String(localized: "不可访问"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .zeyingAlignedGroupedSectionHeader()
                } footer: {
                    Text(String(localized: "这些记录会保留，直到你明确调整权限或清理本地记录。"))
                }
            }

            if !unavailableAlbumItems.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "有 \(unavailableAlbumItems.count) 条相簿整理记录暂时无法访问。"))
                            .font(.subheadline.weight(.medium))
                        Text(library.authorizationStatus == .limited
                             ? String(localized: "它们可能属于尚未授权给择影的照片；调整可访问范围后会重新出现。")
                             : String(localized: "它们可能对应已被删除或移出当前图库的照片。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                } header: {
                    Label(String(localized: "不可访问的相簿整理"), systemImage: "exclamationmark.triangle")
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
                accessibilityLabel: String(localized: "恢复全部 \(deleteIDs.count) 张待删除照片")
            ) {
                recoverDeletions(deleteIDs)
            }
            sectionAction(
                String(localized: "删除全部"),
                accessibilityLabel: String(localized: "确认删除 \(deleteIDs.count) 张")
            ) {
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
                Button {
                    recoverDeletions([identifier])
                } label: {
                    summaryAssetRowContent(asset: asset, isDeletion: true, trailingTitle: String(localized: "恢复"))
                }
                .buttonStyle(.plain)
                .disabled(isCommitting)
                .accessibilityLabel(String(localized: "恢复这张待删除照片"))
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
                .accessibilityLabel(String(localized: "编辑待收藏照片"))
            }
        }
    }

    private func summaryAssetRowContent(asset: PHAsset, isDeletion: Bool, trailingTitle: String) -> some View {
        HStack(spacing: 12) {
            AssetImageView(asset: asset, library: library, contentMode: .fill)
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
            Text(trailingTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(isDeletion ? Color.blue : Color.secondary)
        }
        .contentShape(Rectangle())
    }

    private func recoverDeletions(_ identifiers: [String]) {
        guard reviews.recoverPendingDeletions(identifiers) else {
            operationError = reviews.errorMessage ?? String(localized: "无法恢复待删除照片。")
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
                    AssetImageView(asset: asset, library: library, contentMode: .fill)
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
            .accessibilityLabel(String(localized: "编辑加入相簿 \(assignment.albumTitle) 的照片"))
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
            operationError = error.localizedDescription
            showingError = true
        }
    }

    private func commitAlbumAssignments() async {
        let requested = albumItems
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
                    if saved { albumService.recordSelection(of: identifier) }
                    return saved
                }
            )
            guard albumAssignments.removeApplied(result.appliedIdentifiers) else {
                operationError = albumAssignments.errorMessage ?? String(localized: "无法清除已完成的相簿整理记录。")
                showingError = true
                return
            }
            if !result.failedIdentifiers.isEmpty || result.errorMessage != nil {
                let detail = result.errorMessage ?? String(localized: "部分照片未能加入相簿。")
                operationError = String(localized: "已完成 \(result.appliedIdentifiers.count) 张，仍有 \(result.failedIdentifiers.count) 张待处理。\n\(detail)")
                showingError = true
            }
            await library.refresh()
        } catch {
            operationError = error.localizedDescription
            showingError = true
        }
    }

    private func commitDeletes() async {
        let requestedIDs = deleteIDs
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
                operationError = albumAssignments.errorMessage ?? String(localized: "照片已删除，但相簿整理记录未能清除。")
                showingError = true
                return
            }
            if let statisticsError {
                operationError = statisticsError
                showingError = true
            }
        } catch {
            operationError = error.localizedDescription
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
}
