import Photos
import SwiftUI
import UIKit

struct ReviewQueueView: View {
    private let sourceScope: LibraryScope?
    private let explicitAssetIDs: [String]?
    private let library: PhotoLibraryService
    private let reviews: ReviewStore
    private let sizes: AssetSizeService
    private let albumService: PhotoAlbumService
    private let albumAssignments: PendingAlbumAssignmentStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSummaryTab) private var openSummaryTab
    @Environment(AppSettings.self) private var settings
    @Environment(ReviewResumeStore.self) private var resume

    @State private var queueIDs: [String] = []
    @State private var upcomingPreviewIdentifier: String?
    @State private var upcomingPreview: UIImage?
    @State private var handoffPreviewIdentifier: String?
    @State private var handoffPreview: UIImage?
    @State private var hasLoaded = false
    @State private var sourceTotalCount: Int?
    @State private var index = 0
    @State private var processedCount = 0
    @State private var dragOffset: CGFloat = 0
    @State private var downwardOffset: CGFloat = 0
    @State private var swipeAxis: ReviewSwipeAxis?
    @State private var cardWidth: CGFloat = 320
    @State private var cardHeight: CGFloat = 480
    @State private var cardAreaHeight: CGFloat = 600
    @State private var videoCardFrame: CGRect = .zero
    @State private var actionHistory: [QueueAction] = []
    @State private var showingInfo = false
    @State private var showingNewAlbumPrompt = false
    @State private var newAlbumTitle = ""
    @State private var showingUnfavoriteConfirmation = false
    @State private var favoriteRemovalIdentifier: String?
    @State private var showingAlbumRemovalConfirmation = false
    @State private var albumRemovalTarget: AlbumRemovalTarget?
    @State private var isUpdatingLibrary = false
    @State private var conversionSelection: LiveConversionSelection?
    @State private var shareFile: ReviewShareFile?
    @State private var shareFileForCleanup: URL?
    @State private var isPreparingShare = false
    @State private var showingError = false
    @State private var operationError: String?
    @State private var isZooming = false
    @State private var isPinching = false
    @State private var isPanningPreview = false
    @GestureState private var isLivePhotoPressed = false
    @State private var isTransitioning = false
    @State private var activeTransitionID: UUID?
    @State private var previewScale: CGFloat = 1
    @State private var previewOffset: CGSize = .zero
    @State private var videoSoundEnabled = false
    @State private var pinchStartScale: CGFloat = 1
    @State private var panStartOffset: CGSize = .zero
    @State private var panTranslation: CGSize = .zero

    init(
        scope: LibraryScope,
        library: PhotoLibraryService,
        reviews: ReviewStore,
        sizes: AssetSizeService,
        albumService: PhotoAlbumService,
        albumAssignments: PendingAlbumAssignmentStore
    ) {
        self.sourceScope = scope
        self.explicitAssetIDs = nil
        self.library = library
        self.reviews = reviews
        self.sizes = sizes
        self.albumService = albumService
        self.albumAssignments = albumAssignments
    }

    init(
        assetIDs: [String],
        library: PhotoLibraryService,
        reviews: ReviewStore,
        sizes: AssetSizeService,
        albumService: PhotoAlbumService,
        albumAssignments: PendingAlbumAssignmentStore
    ) {
        self.sourceScope = nil
        self.explicitAssetIDs = assetIDs
        self.library = library
        self.reviews = reviews
        self.sizes = sizes
        self.albumService = albumService
        self.albumAssignments = albumAssignments
    }

    private var currentAsset: PHAsset? {
        guard queueIDs.indices.contains(index) else { return nil }
        return library.asset(with: queueIDs[index])
    }

    private var upcomingAsset: PHAsset? {
        guard queueIDs.indices.contains(index + 1) else { return nil }
        return library.asset(with: queueIDs[index + 1])
    }

    private var isComplete: Bool {
        hasLoaded && (queueIDs.isEmpty || index >= queueIDs.count)
    }

    private var remainingCount: Int {
        max(queueIDs.count - index, 0)
    }

    private var pendingConfirmationCount: Int {
        let deletions = reviews.identifiers(with: .delete)
            .filter { library.asset(with: $0) != nil }
            .count
        let favorites = reviews.pendingFavoriteIdentifiers
            .filter { library.asset(with: $0) != nil }
            .count
        return deletions + favorites + albumAssignments.count +
            LivePhotoConversionManager.shared.pendingConversions.count +
            (LivePhotoConversionManager.shared.journalError == nil ? 0 : 1)
    }

    private var canUndoHere: Bool {
        guard let action = actionHistory.last else { return false }
        return reviews.latestUndoToken == action.undoToken
    }

    private var queueTitle: String {
        guard let sourceScope else { return String(localized: "编辑决定") }
        if case .month = sourceScope, let date = currentAsset?.creationDate {
            return date.zeyingShortDate
        }
        if case .album(let identifier) = sourceScope {
            return library.albums.first(where: { $0.id == identifier })?.title ?? String(localized: "相簿")
        }
        return sourceScope.zeyingTitle
    }

    private var queueNavigationTitle: some View {
        HStack(spacing: 4) {
            Text(queueTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let date = queueHeaderDate {
                Text("· \(date.zeyingShortDate)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityElement(children: .combine)
    }

    private var queueHeaderDate: Date? {
        guard let sourceScope else { return nil }
        if case .month = sourceScope { return nil }
        return currentAsset?.creationDate
    }

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView(String(localized: "正在准备照片…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isComplete {
                completedContent
            } else if let currentAsset {
                reviewContent(for: currentAsset)
            } else {
                missingAssetContent
            }
        }
        .navigationTitle(queueTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        // The review surface uses horizontal drags all the way to the screen
        // edge. Keep the system's content/edge pop gestures from taking them;
        // the navigation bar's back button remains available.
        .background(ReviewNavigationSwipeGuard().frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if sourceScope != nil, remainingCount > 1 {
                    Button {
                        shuffleRemaining()
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .disabled(isTransitioning || isPreparingShare || isLivePhotoPressed)
                    .accessibilityLabel(String(localized: "随机审查本组照片与视频"))
                    .accessibilityHint(String(localized: "只打乱当前分类中尚未处理的顺序，仍可撤销上一步"))
                }
            }
            ToolbarItem(placement: .principal) {
                queueNavigationTitle
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !isComplete, let currentAsset {
                    HStack(spacing: 8) {
                        Button {
                            showingInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel(String(localized: "照片信息"))

                        if currentAsset.mediaSubtypes.contains(.photoLive) {
                            Button {
                                conversionSelection = LiveConversionSelection(id: currentAsset.localIdentifier)
                            } label: {
                                Image(systemName: "livephoto.slash")
                            }
                            .accessibilityLabel(String(localized: "转为静态照片"))
                        }

                        Button {
                            Task { await prepareShare(for: currentAsset) }
                        } label: {
                            if isPreparingShare {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .disabled(isPreparingShare)
                        .accessibilityLabel(String(localized: "分享照片或视频"))
                    }
                }
            }
        }
        .sheet(isPresented: $showingInfo) {
            if let currentAsset {
                NavigationStack {
                    ScrollView {
                        AssetInfoView(asset: currentAsset, sizes: sizes)
                            .padding(20)
                    }
                    .navigationTitle(String(localized: "照片信息"))
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $conversionSelection) { selection in
            LivePhotoConversionSheet(
                sourceIdentifier: selection.id,
                library: library,
                reviews: reviews,
                albumAssignments: albumAssignments,
                initialPreview: library.asset(with: selection.id).flatMap {
                    library.cachedReviewPreview(for: $0) ?? library.cachedQuickPreview(for: $0)
                }
            ) {
                if queueIDs.indices.contains(index), queueIDs[index] == selection.id {
                    advance()
                }
            }
        }
        .sheet(item: $shareFile, onDismiss: cleanupShareFile) { file in
            ActivityShareSheet(fileURL: file.url)
        }
        .overlay {
            if isPreparingShare {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView(String(localized: "正在准备分享…"))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .zeyingGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .alert(String(localized: "操作未完成"), isPresented: $showingError) {
            Button(String(localized: "知道了")) {
                operationError = nil
                reviews.clearError()
            }
        } message: {
            Text(operationError ?? reviews.errorMessage ?? String(localized: "请稍后重试。"))
        }
        .alert(String(localized: "新建相簿"), isPresented: $showingNewAlbumPrompt) {
            TextField(String(localized: "相簿名"), text: $newAlbumTitle)
            Button(String(localized: "加入清单")) {
                let title = newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if let currentAsset, !title.isEmpty {
                    stageAlbumSelection(
                        PhotoAlbumSelection(identifier: nil, title: title),
                        for: currentAsset
                    )
                }
                newAlbumTitle = ""
            }
            .disabled(newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(String(localized: "取消"), role: .cancel) { newAlbumTitle = "" }
        } message: {
            Text(String(localized: "相簿会在清单确认后创建。"))
        }
        .confirmationDialog(
            String(localized: "取消系统收藏？"),
            isPresented: $showingUnfavoriteConfirmation,
            titleVisibility: .visible
        ) {
            if let favoriteRemovalIdentifier {
                Button(String(localized: "取消收藏"), role: .destructive) {
                    Task { await unfavorite(favoriteRemovalIdentifier) }
                }
            }
            Button(String(localized: "保留收藏"), role: .cancel) {}
        } message: {
            Text(String(localized: "只会取消系统照片中的收藏标记，照片仍留在图库中。"))
        }
        .confirmationDialog(
            String(localized: "从相簿移除？"),
            isPresented: $showingAlbumRemovalConfirmation,
            titleVisibility: .visible
        ) {
            if let albumRemovalTarget {
                Button(String(localized: "移出相簿 \(albumRemovalTarget.albumTitle)"), role: .destructive) {
                    Task { await removeFromAlbum(albumRemovalTarget) }
                }
            }
            Button(String(localized: "保留在相簿中"), role: .cancel) {}
        } message: {
            Text(String(localized: "只从这个相簿移除，照片仍留在图库和其他相簿中。"))
        }
        .task {
            await loadQueueIfNeeded()
        }
    }

    private func reviewContent(for asset: PHAsset) -> some View {
        VStack(spacing: 10) {
            progressHeader

            HStack(spacing: 8) {
                albumCarousel(for: asset)
                    .frame(maxWidth: .infinity)
                AssetSizeCapsule(asset: asset, sizes: sizes)
                    .fixedSize()
            }

            GeometryReader { proxy in
                let foregroundSize = fittedCardSize(for: asset, in: proxy.size)
                let nextAsset = upcomingAsset
                let nextSize = nextAsset.map { fittedCardSize(for: $0, in: proxy.size) }
                let nextImage = nextAsset.flatMap(cachedUpcomingPreview)
                let revealDistance = max(foregroundSize.width + 120, 360)
                let verticalRevealDistance = max((proxy.size.height + foregroundSize.height) / 2 + 120, 360)
                let nextOpacity = reduceMotion ? 0 : min(max(
                    abs(dragOffset) / revealDistance,
                    downwardOffset / verticalRevealDistance
                ), 1)
                let availableFrame = proxy.frame(in: .global)
                let foregroundFrame = CGRect(
                    x: availableFrame.midX - foregroundSize.width / 2,
                    y: availableFrame.midY - foregroundSize.height / 2,
                    width: foregroundSize.width,
                    height: foregroundSize.height
                )
                ZStack {
                    // Keep the screen sides tappable even when a landscape photo
                    // occupies only the center of the available card area.
                    DecisionTapZones(
                        isVideo: false,
                        decisionEnabled: !isTransitioning && !isLivePhotoPressed &&
                            (asset.mediaType == .video || (!isZooming && previewScale <= 1.01))
                    ) {
                        perform(.delete)
                    } onKeep: {
                        perform(.keep)
                    }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        // This invisible surface handles swipes in the empty
                        // space around landscape media without competing with
                        // video playback controls.
                        .highPriorityGesture(swipeGesture)

                    if let nextImage, let nextSize {
                        Image(uiImage: nextImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: nextSize.width, height: nextSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            // The next image stays invisible at rest. Its reveal
                            // tracks the same distance used to dismiss this card.
                            .opacity(nextOpacity)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    reviewCard(for: asset)
                        .frame(width: foregroundSize.width, height: foregroundSize.height)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear {
                    cardWidth = foregroundSize.width
                    cardHeight = foregroundSize.height
                    cardAreaHeight = proxy.size.height
                    videoCardFrame = foregroundFrame
                }
                .onChange(of: foregroundSize) { _, size in
                    cardWidth = size.width
                    cardHeight = size.height
                }
                .onChange(of: foregroundFrame) { _, frame in
                    videoCardFrame = frame
                }
                .onChange(of: proxy.size.height) { _, height in
                    cardAreaHeight = height
                }
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)

            actionBar(for: asset)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .task(id: asset.localIdentifier) {
            let currentIndex = index
            let nextIdentifier = queueIDs.indices.contains(currentIndex + 1) ? queueIDs[currentIndex + 1] : nil
            upcomingPreviewIdentifier = nextIdentifier
            upcomingPreview = upcomingAsset.flatMap {
                library.cachedReviewPreview(for: $0) ?? library.cachedQuickPreview(for: $0)
            }
            library.prefetchReviewPreviews(
                prefetchCandidates(after: currentIndex),
                keeping: asset.localIdentifier
            )
            if let next = upcomingAsset {
                let preview = await library.quickPreview(for: next)
                guard !Task.isCancelled else { return }
                if upcomingPreviewIdentifier == next.localIdentifier {
                    upcomingPreview = library.cachedReviewPreview(for: next) ?? preview
                }
            }
        }
        .task(id: "\(asset.localIdentifier)-\(library.revision)") {
            let libraryRevision = library.revision
            await albumService.loadMemberships(
                for: asset.localIdentifier, libraryRevision: libraryRevision
            )
            if let nextIdentifier = upcomingAsset?.localIdentifier, !Task.isCancelled {
                await albumService.loadMemberships(
                    for: nextIdentifier, libraryRevision: libraryRevision
                )
            }
        }
    }

    private func prefetchCandidates(after currentIndex: Int) -> [PHAsset] {
        guard currentIndex + 1 < queueIDs.count else { return [] }
        return queueIDs[(currentIndex + 1)..<min(currentIndex + 6, queueIDs.count)]
            .compactMap { library.asset(with: $0) }
    }

    private func cachedUpcomingPreview(for asset: PHAsset) -> UIImage? {
        if let image = library.cachedReviewPreview(for: asset) { return image }
        if upcomingPreviewIdentifier == asset.localIdentifier, let upcomingPreview {
            return upcomingPreview
        }
        return library.cachedQuickPreview(for: asset)
    }

    private func fittedCardSize(for asset: PHAsset, in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0 else { return .zero }
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return available }
        let scale = min(
            available.width / CGFloat(asset.pixelWidth),
            available.height / CGFloat(asset.pixelHeight)
        )
        return CGSize(
            width: CGFloat(asset.pixelWidth) * scale,
            height: CGFloat(asset.pixelHeight) * scale
        )
    }

    private func albumCarousel(for asset: PHAsset) -> some View {
        let assignment = albumAssignments.assignment(for: asset.localIdentifier)
        let memberships = albumService.memberships(for: asset.localIdentifier)
        let memberIdentifiers = Set(memberships?.map(\.id) ?? [])
        return HStack(spacing: 0) {
            Text(String(localized: "相簿整理"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .fixedSize(horizontal: true, vertical: false)

            Rectangle()
                .fill(.secondary.opacity(0.18))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 7)
                .accessibilityHidden(true)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    if memberships == nil {
                        Text(String(localized: "正在读取相簿…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 44)
                    }
                    if let memberships {
                        ForEach(memberships) { album in
                            Button {
                                albumRemovalTarget = AlbumRemovalTarget(
                                    assetIdentifier: asset.localIdentifier,
                                    albumIdentifier: album.id,
                                    albumTitle: album.title
                                )
                                showingAlbumRemovalConfirmation = true
                            } label: {
                                Label(album.title, systemImage: "checkmark")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 11)
                                    .frame(height: 30)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    .frame(height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!album.canRemove || isUpdatingLibrary)
                            .accessibilityLabel(album.canRemove
                                ? String(localized: "已在相簿 \(album.title)，点按可移除")
                                : String(localized: "已在相簿 \(album.title)"))
                        }

                        ForEach(albumService.frequentlyUsedFirst.filter { !memberIdentifiers.contains($0.id) }) { album in
                            let isPending = assignment?.albumIdentifier == album.id
                            Button {
                                stageAlbumSelection(
                                    PhotoAlbumSelection(identifier: album.id, title: album.title),
                                    for: asset
                                )
                            } label: {
                                HStack(spacing: 4) {
                                    if isPending { Image(systemName: "clock") }
                                    Text(album.title)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(isPending ? Color.accentColor : Color.primary)
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(isPending ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                                            in: Capsule())
                                .frame(height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isUpdatingLibrary)
                            .accessibilityLabel(isPending
                                ? String(localized: "待加入相簿 \(album.title)")
                                : String(localized: "加入相簿 \(album.title)"))
                        }

                        Button {
                            newAlbumTitle = ""
                            showingNewAlbumPrompt = true
                        } label: {
                            Label(String(localized: "新建"), systemImage: "plus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                                .frame(height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isUpdatingLibrary)
                        .accessibilityLabel(String(localized: "新建相簿并加入清单"))
                    }
                }
                .padding(.horizontal, 7)
            }
        }
        .frame(height: 44)
        .zeyingGlass(in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityHint(String(localized: "左右滑动可查看更多相簿；选择后视为保留"))
    }

    private func decisionTapZones(for asset: PHAsset) -> some View {
        DecisionTapZones(
            isVideo: asset.mediaType == .video,
            decisionEnabled: !isTransitioning && !isLivePhotoPressed &&
                (asset.mediaType == .video || (!isZooming && previewScale <= 1.01))
        ) {
            perform(.delete)
        } onKeep: {
            perform(.keep)
        }
    }

    @ViewBuilder
    private func reviewCard(for asset: PHAsset) -> some View {
        let content = ZStack {
            AssetPreviewView(
                asset: asset,
                library: library,
                videoSoundEnabled: $videoSoundEnabled,
                initialPreview: handoffPreviewIdentifier == asset.localIdentifier ? handoffPreview : nil,
                isLivePhotoPressed: isLivePhotoPressed
            )
                .scaleEffect(asset.mediaType == .image ? previewScale : 1)
                .offset(asset.mediaType == .image ? previewOffset : .zero)

            decisionTapZones(for: asset)

            swipeHint
                .allowsHitTesting(false)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(
            color: .black.opacity(reduceMotion ? 0.12 : 0.18),
            radius: reduceMotion ? 10 : 16,
            y: reduceMotion ? 5 : 9
        )
        // Apply the transform after clipping so the complete rounded card can
        // leave the viewport as one physical surface.
        .offset(x: dragOffset, y: downwardOffset)
        .rotationEffect(.degrees(cardRotationAngle))

        if asset.mediaType == .video {
            content
                .simultaneousGesture(videoSwipeGesture, including: .all)
        } else {
            let interactive = content
                .simultaneousGesture(swipeGesture)
                .simultaneousGesture(previewZoomGesture)
                .simultaneousGesture(previewPanGesture)
                .task(id: asset.localIdentifier) {
                    resetPreviewZoom()
                }
            if asset.mediaSubtypes.contains(.photoLive) {
                interactive.simultaneousGesture(livePhotoPressGesture)
            } else {
                interactive
            }
        }
    }

    private var cardRotationAngle: Double {
        guard cardWidth > 0 else { return 0 }
        return Double(dragOffset / cardWidth) * 14
    }

    private var progressHeader: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(min(index + 1, max(queueIDs.count, 1))) / \(queueIDs.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer()
                if let sourceTotalCount {
                    Text(String(localized: "本组 \(sourceTotalCount) 张"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(String(localized: "剩余 \(remainingCount)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(min(index, queueIDs.count)), total: Double(max(queueIDs.count, 1)))
                .tint(.primary)
                .accessibilityLabel(String(localized: "审核进度"))
                .accessibilityValue(String(localized: "已处理 \(processedCount) 张，共 \(queueIDs.count) 张"))
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var swipeHint: some View {
        decisionBadge(
            title: String(localized: "待删除"),
            symbol: "xmark",
            tint: .red,
            distance: -dragOffset
        )
        decisionBadge(
            title: String(localized: "保留"),
            symbol: "heart.fill",
            tint: .cyan,
            distance: dragOffset
        )
        decisionBadge(
            title: String(localized: "待决定"),
            symbol: "questionmark",
            tint: .orange,
            distance: downwardOffset,
            revealStart: 70,
            revealRange: 90
        )
    }

    private func decisionBadge(
        title: String,
        symbol: String,
        tint: Color,
        distance: CGFloat,
        revealStart: CGFloat = 8,
        revealRange: CGFloat = 82
    ) -> some View {
        let opacity = min(max((distance - revealStart) / revealRange, 0), 1)
        let growth = min(max((distance - revealStart - 37) / 100, 0), 1)
        return Label(title, systemImage: symbol)
            .font(.system(size: 30, weight: .heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 17)
            .padding(.vertical, 11)
            .shadow(color: .black.opacity(0.75), radius: 8, y: 2)
            .opacity(opacity)
            .scaleEffect(reduceMotion ? 1 : 0.94 + 0.22 * growth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(20)
    }

    private func actionBar(for asset: PHAsset) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Keep the destructive action at the same side as a left swipe.
            primaryActionButton(
                symbol: "xmark",
                title: String(localized: "删除"),
                tint: .red,
                accessibilityLabel: String(localized: "待删除"),
                accessibilityHint: String(localized: "将照片加入待删除清单")
            ) {
                perform(.delete)
            }

            Spacer(minLength: 4)

            compactActionButton(
                symbol: "arrow.uturn.backward",
                title: String(localized: "撤销"),
                tint: canUndoHere ? .primary : .secondary.opacity(0.35),
                accessibilityLabel: String(localized: "撤销上一步"),
                accessibilityHint: canUndoHere ? String(localized: "撤销这张照片的决定") : String(localized: "当前没有可撤销的操作")
            ) {
                undoLastAction()
            }
            .disabled(!canUndoHere || isTransitioning)

            Spacer(minLength: 4)

            compactActionButton(
                symbol: "questionmark",
                title: String(localized: "待决定"),
                tint: .secondary,
                accessibilityLabel: String(localized: "暂不决定"),
                accessibilityHint: String(localized: "点按或明显向下滑动可放入待决定分类")
            ) {
                perform(.later)
            }

            Spacer(minLength: 4)

            compactActionButton(
                symbol: asset.isFavorite || reviews.isPendingFavorite(asset.localIdentifier) ? "star.fill" : "star",
                title: asset.isFavorite ? String(localized: "取消收藏") : String(localized: "收藏"),
                tint: .yellow,
                accessibilityLabel: asset.isFavorite ? String(localized: "取消系统收藏") : String(localized: "收藏并保留"),
                accessibilityHint: asset.isFavorite
                    ? String(localized: "这张照片已在系统照片中收藏；点按可取消收藏，不会删除照片")
                    : String(localized: "暂存收藏，稍后确认后同步到系统照片")
            ) {
                if asset.isFavorite {
                    favoriteRemovalIdentifier = asset.localIdentifier
                    showingUnfavoriteConfirmation = true
                } else {
                    stageFavorite(for: asset)
                }
            }

            Spacer(minLength: 4)

            // Keep the preserving action at the same side as a right swipe.
            primaryActionButton(
                symbol: "heart.fill",
                title: String(localized: "保留"),
                tint: .cyan,
                accessibilityLabel: String(localized: "保留"),
                accessibilityHint: String(localized: "将照片标记为保留")
            ) {
                perform(.keep)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 76, alignment: .top)
        .disabled(isUpdatingLibrary)
        .accessibilityElement(children: .contain)
    }

    private func primaryActionButton(
        symbol: String,
        title: String,
        tint: Color,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            circularActionButton(
                symbol: symbol,
                tint: tint,
                diameter: 68,
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: accessibilityHint,
                action: action
            )
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityHidden(true)
        }
        .frame(width: 68)
    }

    private func compactActionButton(
        symbol: String,
        title: String,
        tint: Color,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 3) {
            circularActionButton(
                symbol: symbol,
                tint: tint,
                diameter: 42,
                accessibilityLabel: accessibilityLabel,
                accessibilityHint: accessibilityHint,
                action: action
            )
            .frame(height: 68)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityHidden(true)
        }
        .frame(width: 60)
    }

    private func circularActionButton(
        symbol: String,
        tint: Color,
        diameter: CGFloat,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter >= 60 ? 28 : 19, weight: .semibold))
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(ReviewCircleButtonStyle(tint: tint, diameter: diameter))
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var missingAssetContent: some View {
        ZeyingEmptyState(
            symbol: "photo.badge.exclamationmark",
            title: String(localized: "照片暂时不可用"),
            message: String(localized: "这张照片可能已被移除，返回后会自动跳过。"),
            actionTitle: String(localized: "跳过")
        ) {
            advance()
        }
    }

    private var completedContent: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.green)

            VStack(spacing: 7) {
                Text(String(localized: "这一组处理完了"))
                    .font(.title2.weight(.semibold))
                Text(String(localized: "已完成 \(processedCount) 张照片的决定。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if pendingConfirmationCount > 0 {
                    Text(String(localized: "还有 \(pendingConfirmationCount) 项待完成操作，可到清单继续确认。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 5)
                }
            }

            VStack(spacing: 7) {
                Button {
                    dismiss()
                    openSummaryTab?()
                } label: {
                    Label(pendingConfirmationCount > 0 ? String(localized: "去清单继续") : String(localized: "查看清单"), systemImage: "checklist")
                }
                .buttonStyle(ZeyingGlassButtonStyle())

                Text(String(localized: "底部导航会切换到“清单”页面。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if canUndoHere {
                Button {
                    undoLastAction()
                } label: {
                    Label(String(localized: "撤销上一步"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(ZeyingGlassButtonStyle())
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func loadQueueIfNeeded() async {
        guard !hasLoaded else { return }
        await library.ensureLoaded()
        albumService.refresh()

        let identifiers: [String]
        if let explicitAssetIDs {
            identifiers = explicitAssetIDs
        } else if sourceScope == .later {
            identifiers = reviews.identifiers(with: .later)
        } else if let sourceScope {
            let scopedAssets = library.assets(in: sourceScope)
            sourceTotalCount = scopedAssets.count
            let unreviewed = scopedAssets
                .filter { reviews.decision(for: $0.localIdentifier) == nil }
            // PhotoLibraryService fetches each scope newest first. Review the
            // remaining assets oldest first, while keeping random mode random.
            identifiers = sourceScope == .random
                ? unreviewed.shuffled().map(\.localIdentifier)
                : unreviewed.reversed().map(\.localIdentifier)
        } else {
            identifiers = []
        }

        var seenIdentifiers: Set<String> = []
        queueIDs = identifiers.filter { seenIdentifiers.insert($0).inserted }
        if let firstIdentifier = queueIDs.first {
            library.prefetchReviewPreviews(
                prefetchCandidates(after: 0),
                keeping: firstIdentifier
            )
        }
        hasLoaded = true
        rememberCurrentScopeIfNeeded()
    }

    private func rememberCurrentScopeIfNeeded() {
        guard let sourceScope, sourceScope != .later,
              queueIDs.indices.contains(index),
              let asset = library.asset(with: queueIDs[index]) else {
            return
        }
        resume.remember(scope: sourceScope, containing: asset.creationDate)
    }

    private func shuffleRemaining() {
        guard sourceScope != nil, remainingCount > 1,
              !isTransitioning, !isPreparingShare, !isLivePhotoPressed else { return }

        let currentIdentifier = queueIDs[index]
        var remaining = Array(queueIDs[index...])
        remaining.shuffle()
        if remaining[0] == currentIdentifier {
            remaining.swapAt(0, Int.random(in: 1..<remaining.count))
        }

        // Earlier indices remain untouched, so every undo token still points
        // to the photo on which the original decision was made.
        upcomingPreviewIdentifier = nil
        upcomingPreview = nil
        resetPreviewZoom()
        dragOffset = 0
        downwardOffset = 0
        swipeAxis = nil
        queueIDs.replaceSubrange(index..<queueIDs.count, with: remaining)
        library.prefetchReviewPreviews(
            prefetchCandidates(after: index),
            keeping: remaining[0]
        )
        emitDecisionHaptic()
        rememberCurrentScopeIfNeeded()
    }

    private var swipeGesture: some Gesture {
        // The card itself moves with the drag. Measure in screen coordinates
        // so its changing local origin cannot make the translation jump.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { handleSwipeChanged($0.translation) }
            .onEnded {
                handleSwipeEnded(
                    $0.translation,
                    predictedEndTranslation: $0.predictedEndTranslation
                )
            }
    }

    private var videoSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard videoSwipeCanBegin(at: value.startLocation) else { return }
                handleSwipeChanged(value.translation)
            }
            .onEnded { value in
                guard videoSwipeCanBegin(at: value.startLocation) else {
                    resetDrag()
                    return
                }
                handleSwipeEnded(
                    value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                )
            }
    }

    private func videoSwipeCanBegin(at point: CGPoint) -> Bool {
        guard videoCardFrame.contains(point) else { return false }
        let localX = point.x - videoCardFrame.minX
        let localY = point.y - videoCardFrame.minY
        let playbackControlsHeight = min(max(videoCardFrame.height * 0.22, 60), 90)
        guard localY < videoCardFrame.height - playbackControlsHeight else { return false }
        // The sound button owns the upper-right corner of the video.
        return !(localX > videoCardFrame.width - 72 && localY < 72)
    }

    private func prepareShare(for asset: PHAsset) async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        do {
            let fileURL = try await library.exportForSharing(asset)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            shareFileForCleanup = fileURL
            shareFile = ReviewShareFile(url: fileURL)
        } catch {
            operationError = String(localized: "无法准备分享文件：\(error.localizedDescription)")
            showingError = true
        }
    }

    private func cleanupShareFile() {
        if let shareFileForCleanup {
            try? FileManager.default.removeItem(at: shareFileForCleanup)
        }
        shareFileForCleanup = nil
    }

    private func handleSwipeChanged(_ translation: CGSize) {
        guard !isTransitioning, !isZooming, !isLivePhotoPressed,
              previewScale <= 1.01 else { return }
        if swipeAxis == nil {
            swipeAxis = ReviewSwipeClassifier.axis(for: translation)
        }
        guard let swipeAxis else { return }
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            switch swipeAxis {
            case .horizontal:
                dragOffset = translation.width
                downwardOffset = 0
            case .downward:
                dragOffset = 0
                downwardOffset = max(translation.height, 0)
            }
        }
    }

    private func handleSwipeEnded(_ translation: CGSize, predictedEndTranslation: CGSize? = nil) {
        let finishedAxis = swipeAxis ?? ReviewSwipeClassifier.axis(for: translation)
        swipeAxis = nil
        guard !isTransitioning, !isZooming, !isLivePhotoPressed,
              previewScale <= 1.01 else {
            resetDrag()
            return
        }
        if finishedAxis == .downward {
            if ReviewSwipeClassifier.commitsUndecided(translation) {
                perform(.later)
            } else {
                resetDrag()
            }
            return
        }
        guard finishedAxis == .horizontal,
              abs(translation.width) > abs(translation.height) else {
            resetDrag()
            return
        }
        // Use the predicted end only for a quick flick. This keeps a slow drag
        // faithful to the finger while allowing a confident flick to complete
        // without a sticky pause at the threshold.
        let predictedWidth = predictedEndTranslation?.width ?? translation.width
        let effectiveWidth: CGFloat
        if abs(predictedWidth) > abs(translation.width) * 1.18 {
            effectiveWidth = predictedWidth
        } else {
            effectiveWidth = translation.width
        }

        if effectiveWidth < -90 {
            perform(.delete)
        } else if effectiveWidth > 90 {
            perform(.keep)
        } else {
            resetDrag()
        }
    }

    private func perform(_ decision: ReviewDecision) {
        guard !isTransitioning, !isPreparingShare, !isUpdatingLibrary,
              let currentAsset else { return }
        let previousAlbumAssignment = albumAssignmentSnapshot(for: currentAsset.localIdentifier)
        let identifier = currentAsset.localIdentifier
        emitDecisionHaptic()
        playDecisionExit(for: decision) {
            recordDecision(
                decision,
                for: identifier,
                previousAlbumAssignment: previousAlbumAssignment
            )
        }
    }

    private func recordDecision(
        _ decision: ReviewDecision,
        for identifier: String,
        previousAlbumAssignment: QueueAlbumAssignment?
    ) -> Bool {
        if decision != .keep, !clearAlbumAssignment(for: identifier) {
            return false
        }
        guard reviews.decide(decision, for: identifier) else {
            _ = restoreAlbumAssignment(previousAlbumAssignment, for: identifier)
            showingError = true
            return false
        }
        if let undoToken = reviews.latestUndoToken {
            actionHistory.append(
                QueueAction(
                    indexBefore: index,
                    undoToken: undoToken,
                    previousAlbumAssignment: previousAlbumAssignment
                )
            )
        }
        processedCount += 1
        return true
    }

    private func stageAlbumSelection(_ selection: PhotoAlbumSelection, for asset: PHAsset) {
        guard !isTransitioning, !isPreparingShare, !isUpdatingLibrary else { return }
        let previousAlbumAssignment = albumAssignmentSnapshot(for: asset.localIdentifier)
        guard albumAssignments.assign(
            assetIdentifier: asset.localIdentifier,
            albumIdentifier: selection.identifier,
            albumTitle: selection.title
        ) else {
            operationError = albumAssignments.errorMessage ?? String(localized: "无法暂存相簿整理。")
            showingError = true
            return
        }

        // An album target is a keep action. Persist the keep state alongside
        // the independent album assignment so every entry point agrees.
        guard reviews.decide(.keep, for: asset.localIdentifier) else {
            _ = restoreAlbumAssignment(previousAlbumAssignment, for: asset.localIdentifier)
            showingError = true
            return
        }
        emitDecisionHaptic()
        if let undoToken = reviews.latestUndoToken {
            actionHistory.append(
                QueueAction(
                    indexBefore: index,
                    undoToken: undoToken,
                    previousAlbumAssignment: previousAlbumAssignment
                )
            )
        }
        processedCount += 1
        newAlbumTitle = ""
        if let identifier = selection.identifier {
            albumService.recordSelection(of: identifier)
        }
        playDecisionExit(for: .keep)
    }

    private func stageFavorite(for asset: PHAsset) {
        guard !isTransitioning, !isPreparingShare, !isUpdatingLibrary else { return }
        let previousAlbumAssignment = albumAssignmentSnapshot(for: asset.localIdentifier)
        guard reviews.stageFavorite(for: asset.localIdentifier, alreadyFavorite: asset.isFavorite) else {
            showingError = true
            return
        }
        emitDecisionHaptic()
        if let undoToken = reviews.latestUndoToken {
            actionHistory.append(
                QueueAction(
                    indexBefore: index,
                    undoToken: undoToken,
                    previousAlbumAssignment: previousAlbumAssignment
                )
            )
        }
        processedCount += 1
        advance()
    }

    private func unfavorite(_ identifier: String) async {
        guard !isUpdatingLibrary else { return }
        isUpdatingLibrary = true
        defer { isUpdatingLibrary = false }
        do {
            try await library.unfavorite(identifier)
            if reviews.isPendingFavorite(identifier), !reviews.markFavorited([identifier]) {
                throw PhotoLibraryServiceError.changeFailed(
                    reviews.errorMessage ?? String(localized: "已取消系统收藏，但本地待办未能更新。")
                )
            }
            emitDecisionHaptic()
        } catch {
            operationError = error.localizedDescription
            showingError = true
        }
    }

    private func removeFromAlbum(_ target: AlbumRemovalTarget) async {
        guard !isUpdatingLibrary else { return }
        isUpdatingLibrary = true
        defer { isUpdatingLibrary = false }
        do {
            try await albumService.remove(
                assetIdentifier: target.assetIdentifier,
                from: target.albumIdentifier
            )
            if albumAssignments.assignment(for: target.assetIdentifier)?.albumIdentifier == target.albumIdentifier,
               !albumAssignments.remove(assetIdentifier: target.assetIdentifier) {
                throw PhotoLibraryServiceError.changeFailed(
                    albumAssignments.errorMessage ?? String(localized: "照片已从相簿移除，但本地待办未能更新。")
                )
            }
            await albumService.loadMemberships(
                for: target.assetIdentifier, libraryRevision: library.revision
            )
            emitDecisionHaptic()
        } catch {
            operationError = error.localizedDescription
            showingError = true
        }
    }

    private func undoLastAction() {
        guard !isTransitioning, !isPreparingShare else { return }
        guard let action = actionHistory.last else { return }
        let identifier = queueIDs.indices.contains(action.indexBefore) ? queueIDs[action.indexBefore] : nil
        let currentAlbumAssignment = identifier.flatMap(albumAssignmentSnapshot(for:))
        if let identifier,
           !restoreAlbumAssignment(action.previousAlbumAssignment, for: identifier) {
            operationError = albumAssignments.errorMessage ?? String(localized: "无法撤销相簿整理。")
            showingError = true
            return
        }
        guard reviews.undo(matching: action.undoToken) else {
            if let identifier {
                _ = restoreAlbumAssignment(currentAlbumAssignment, for: identifier)
            }
            return
        }
        emitDecisionHaptic()
        actionHistory.removeLast()
        index = action.indexBefore
        rememberCurrentScopeIfNeeded()
        processedCount = max(processedCount - 1, 0)
        resetDrag()
    }

    private func albumAssignmentSnapshot(for identifier: String) -> QueueAlbumAssignment? {
        guard let assignment = albumAssignments.assignment(for: identifier) else { return nil }
        return QueueAlbumAssignment(
            albumIdentifier: assignment.albumIdentifier,
            albumTitle: assignment.albumTitle
        )
    }

    @discardableResult
    private func restoreAlbumAssignment(
        _ snapshot: QueueAlbumAssignment?,
        for identifier: String
    ) -> Bool {
        if let snapshot {
            return albumAssignments.assign(
                assetIdentifier: identifier,
                albumIdentifier: snapshot.albumIdentifier,
                albumTitle: snapshot.albumTitle
            )
        }
        return albumAssignments.remove(assetIdentifier: identifier)
    }

    private func clearAlbumAssignment(for identifier: String) -> Bool {
        guard albumAssignments.assignment(for: identifier) != nil else { return true }
        guard albumAssignments.remove(assetIdentifier: identifier) else {
            operationError = albumAssignments.errorMessage ?? String(localized: "无法更新相簿整理记录。")
            showingError = true
            return false
        }
        return true
    }

    private func advance() {
        captureUpcomingPreviewForHandoff()
        let action = {
            dragOffset = 0
            downwardOffset = 0
            swipeAxis = nil
            index += 1
            isTransitioning = false
            newAlbumTitle = ""
        }
        if reduceMotion {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction, action)
        } else {
            withAnimation(.snappy(duration: 0.24)) {
                action()
            }
        }
        rememberCurrentScopeIfNeeded()
    }

    private func resetDrag() {
        swipeAxis = nil
        if reduceMotion {
            dragOffset = 0
            downwardOffset = 0
        } else {
            withAnimation(.snappy(duration: 0.2)) {
                dragOffset = 0
                downwardOffset = 0
            }
        }
    }

    private func playDecisionExit(
        for decision: ReviewDecision,
        commitBeforeAdvance: (() -> Bool)? = nil
    ) {
        guard !reduceMotion else {
            guard commitBeforeAdvance?() ?? true else { resetDrag(); return }
            advance()
            return
        }

        isTransitioning = true
        let transitionID = UUID()
        activeTransitionID = transitionID
        withAnimation(.easeOut(duration: 0.16)) {
            if decision == .later {
                let exitDistance = max((cardAreaHeight + cardHeight) / 2 + 120, 360)
                downwardOffset = max(downwardOffset + 160, exitDistance)
            } else {
                let direction: CGFloat = decision == .delete ? -1 : 1
                let exitDistance = max(cardWidth + 120, 360)
                dragOffset = direction * max(abs(dragOffset) + 160, exitDistance)
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            guard activeTransitionID == transitionID else { return }
            guard commitBeforeAdvance?() ?? true else {
                activeTransitionID = nil
                isTransitioning = false
                resetDrag()
                return
            }
            captureUpcomingPreviewForHandoff()
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                dragOffset = 0
                downwardOffset = 0
                swipeAxis = nil
                index += 1
                isTransitioning = false
                activeTransitionID = nil
                newAlbumTitle = ""
            }
            rememberCurrentScopeIfNeeded()
        }
    }

    private func captureUpcomingPreviewForHandoff() {
        guard let next = upcomingAsset else {
            handoffPreviewIdentifier = nil
            handoffPreview = nil
            return
        }
        handoffPreviewIdentifier = next.localIdentifier
        let visiblePreview = upcomingPreviewIdentifier == next.localIdentifier ? upcomingPreview : nil
        handoffPreview = library.cachedReviewPreview(for: next)
            ?? visiblePreview
            ?? library.cachedQuickPreview(for: next)
    }

    private func emitDecisionHaptic() {
        guard settings.hapticsEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    private var previewZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                isPinching = true
                isZooming = true
                previewScale = min(max(pinchStartScale * value, 1), 4)
                previewOffset = clampedPreviewOffset(
                    CGSize(
                        width: panStartOffset.width + panTranslation.width,
                        height: panStartOffset.height + panTranslation.height
                    )
                )
            }
            .onEnded { _ in
                pinchStartScale = previewScale
                if previewScale <= 1.01 {
                    previewScale = 1
                    previewOffset = .zero
                } else {
                    previewOffset = clampedPreviewOffset(previewOffset)
                }
                panStartOffset = CGSize(
                    width: previewOffset.width - panTranslation.width,
                    height: previewOffset.height - panTranslation.height
                )
                isPinching = false
                isZooming = isPanningPreview
            }
    }

    private var previewPanGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                guard previewScale > 1.01 else { return }
                if !isPanningPreview {
                    panStartOffset = CGSize(
                        width: previewOffset.width - value.translation.width,
                        height: previewOffset.height - value.translation.height
                    )
                }
                isPanningPreview = true
                isZooming = true
                panTranslation = value.translation
                previewOffset = clampedPreviewOffset(
                    CGSize(
                        width: panStartOffset.width + panTranslation.width,
                        height: panStartOffset.height + panTranslation.height
                    )
                )
            }
            .onEnded { _ in
                guard isPanningPreview else { return }
                panStartOffset = previewOffset
                panTranslation = .zero
                isPanningPreview = false
                isZooming = isPinching
            }
    }

    private var livePhotoPressGesture: some Gesture {
        // A plain LongPressGesture finishes as soon as its minimum duration
        // elapses. Keep the gesture alive with a zero-distance drag so Live
        // Photo playback continues until the finger actually lifts.
        // A deliberate hold should stay nearly stationary. The previous
        // 44-point tolerance let a slowly starting review swipe play Live.
        LongPressGesture(minimumDuration: 0.9, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isLivePhotoPressed) { value, state, _ in
                guard !isPinching, !isZooming, previewScale <= 1.01,
                      swipeAxis == nil, !isTransitioning else { return }
                switch value {
                case .first(true), .second(true, _):
                    state = true
                default:
                    break
                }
            }
    }

    private func clampedPreviewOffset(_ offset: CGSize) -> CGSize {
        let horizontalLimit = max(0, (previewScale - 1) * cardWidth / 2)
        let verticalLimit = max(0, (previewScale - 1) * cardHeight / 2)
        return CGSize(
            width: min(max(offset.width, -horizontalLimit), horizontalLimit),
            height: min(max(offset.height, -verticalLimit), verticalLimit)
        )
    }

    private func resetPreviewZoom() {
        previewScale = 1
        previewOffset = .zero
        pinchStartScale = 1
        panStartOffset = .zero
        panTranslation = .zero
        isZooming = false
        isPinching = false
        isPanningPreview = false
    }
}

enum ReviewSwipeAxis {
    case horizontal
    case downward
}

enum ReviewSwipeClassifier {
    // A short vertical drag can be part of tapping, video control use, or a
    // failed pinch. Only an unambiguous, long downward drag stages Undecided.
    static let undecidedDistance: CGFloat = 160

    static func axis(for translation: CGSize) -> ReviewSwipeAxis? {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        if translation.height > 0, vertical >= max(24, horizontal * 1.6) {
            return .downward
        }
        if horizontal >= max(24, vertical * 1.2) {
            return .horizontal
        }
        return nil
    }

    static func commitsUndecided(_ translation: CGSize) -> Bool {
        translation.height >= undecidedDistance &&
            translation.height >= abs(translation.width) * 1.6
    }
}

private struct ReviewNavigationSwipeGuard: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var guardedNavigationController: UINavigationController?
        private var edgePopWasEnabled: Bool?
        private var contentPopWasEnabled: Bool?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard guardedNavigationController == nil,
                  let navigationController else { return }
            guardedNavigationController = navigationController
            if let recognizer = navigationController.interactivePopGestureRecognizer {
                edgePopWasEnabled = recognizer.isEnabled
                recognizer.isEnabled = false
            }
            if let recognizer = navigationController.interactiveContentPopGestureRecognizer {
                contentPopWasEnabled = recognizer.isEnabled
                recognizer.isEnabled = false
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            restoreNavigationGestures()
            super.viewWillDisappear(animated)
        }

        func restoreNavigationGestures() {
            if let guardedNavigationController {
                if let edgePopWasEnabled {
                    guardedNavigationController.interactivePopGestureRecognizer?.isEnabled = edgePopWasEnabled
                }
                if let contentPopWasEnabled {
                    guardedNavigationController.interactiveContentPopGestureRecognizer?.isEnabled = contentPopWasEnabled
                }
            }
            guardedNavigationController = nil
            edgePopWasEnabled = nil
            contentPopWasEnabled = nil
        }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreNavigationGestures()
    }
}

private struct LiveConversionSelection: Identifiable {
    let id: String
}

private struct ReviewCircleButtonStyle: ButtonStyle {
    let tint: Color
    let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .foregroundStyle(tint)
            .contentShape(Circle())
            .zeyingGlass(in: Circle())
            .brightness(configuration.isPressed ? 0.12 : 0)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 1.08 : 1))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.13),
                value: configuration.isPressed
            )
    }
}

private struct QueueAction: Equatable {
    let indexBefore: Int
    let undoToken: UUID
    let previousAlbumAssignment: QueueAlbumAssignment?
}

private struct QueueAlbumAssignment: Equatable {
    let albumIdentifier: String?
    let albumTitle: String
}

private struct AlbumRemovalTarget {
    let assetIdentifier: String
    let albumIdentifier: String
    let albumTitle: String
}

private struct ReviewShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct PendingDecisionsView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let sizes: AssetSizeService
    let albumService: PhotoAlbumService
    let albumAssignments: PendingAlbumAssignmentStore

    @State private var showingQueue = false

    private var pendingIDs: [String] {
        reviews.identifiers(with: .later)
            .filter { library.asset(with: $0) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZeyingRootPageTitle(title: String(localized: "待决定"))

            Group {
                if !library.hasLoaded,
                   library.authorizationStatus == .authorized || library.authorizationStatus == .limited {
                    ProgressView(String(localized: "正在读取照片…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pendingIDs.isEmpty {
                    ZeyingEmptyState(
                        symbol: "questionmark.circle",
                        title: String(localized: "没有待决定照片"),
                        message: String(localized: "在审核时点按问号，照片会出现在这里。")
                    )
                } else {
                    continueReviewingButton

                    List {
                        Section {
                            ForEach(pendingIDs, id: \.self) { identifier in
                                if let asset = library.asset(with: identifier) {
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
                                        PendingAssetRow(asset: asset, library: library)
                                    }
                                }
                            }
                        } header: {
                            Text(String(localized: "待决定"))
                                .zeyingAlignedGroupedSectionHeader()
                                .textCase(nil)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 0, for: .scrollContent)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await library.ensureLoaded()
        }
        .sheet(isPresented: $showingQueue) {
            NavigationStack {
                ReviewQueueView(
                    assetIDs: pendingIDs,
                    library: library,
                    reviews: reviews,
                    sizes: sizes,
                    albumService: albumService,
                    albumAssignments: albumAssignments
                )
            }
        }
    }

    private var continueReviewingButton: some View {
        Button {
            showingQueue = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "继续审核"))
                        .font(.subheadline.weight(.semibold))
                    Text(String(localized: "逐张重新决定"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(pendingIDs.count, format: .number)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .buttonStyle(ZeyingGlassButtonStyle())
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
    }
}

private struct PendingAssetRow: View {
    let asset: PHAsset
    let library: PhotoLibraryService

    var body: some View {
        HStack(spacing: 12) {
            AssetImageView(asset: asset, library: library, contentMode: .fill)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(asset.creationDate?.zeyingShortDate ?? String(localized: "日期未知"))
                    .font(.subheadline.weight(.medium))
                Text(asset.mediaType.zeyingTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "待决定照片，\(asset.creationDate?.zeyingShortDate ?? String(localized: "日期未知"))"))
    }
}

extension LibraryScope {
    fileprivate var zeyingTitle: String {
        switch self {
        case .all: String(localized: "全部照片")
        case .random: String(localized: "随机清理")
        case .month(let date): date.zeyingMonthTitle
        case .album(let title): title
        case .category(let category): category.title
        case .later: String(localized: "待决定")
        }
    }
}
