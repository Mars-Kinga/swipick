import AVFAudio
import AVKit
import Combine
import OSLog
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AssetImageView: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    var contentMode: ContentMode = .fit
    var allowNetwork = false
    var targetSize = CGSize(width: 480, height: 480)
    var initialPreview: UIImage?
    var requiresFullQuality = false

    @State private var image: UIImage?
    @State private var activeRequestIdentifier: String?
    @State private var requestGeneration = UUID()
    @State private var hasFullQualityImage = false
    @State private var didFinishPreviewRequest = false

    var body: some View {
        Group {
            if let displayedImage {
                Image(uiImage: displayedImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if didFinishPreviewRequest {
                VStack(spacing: 8) {
                    Image(systemName: "photo.slash")
                        .font(.title3)
                    if max(targetSize.width, targetSize.height) >= 900 {
                        Text(allowNetwork ? String(localized: "照片暂时无法加载") : String(localized: "暂无本地预览"))
                            .font(.caption.weight(.medium))
                        Text(String(localized: "仍可继续作出决定"))
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.secondary.opacity(0.12))
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.12))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if allowNetwork, !didFinishPreviewRequest, max(targetSize.width, targetSize.height) >= 900 {
                ProgressView(String(localized: "正在加载高清照片…"))
                    .font(.caption)
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .task(id: ImageRequestIdentity(assetID: asset.localIdentifier, allowNetwork: allowNetwork, targetSize: targetSize, requiresFullQuality: requiresFullQuality)) {
            await loadImage()
        }
        .accessibilityLabel(String(localized: "照片预览"))
    }

    @MainActor
    private func loadImage() async {
        let requestIdentifier = asset.localIdentifier
        let generation = UUID()
        requestGeneration = generation
        activeRequestIdentifier = requestIdentifier
        hasFullQualityImage = false
        didFinishPreviewRequest = false
        let usesReviewCache = requiresFullQuality && targetSize == CGSize(width: 1_500, height: 1_500)
        if usesReviewCache, let cached = library.cachedReviewPreview(for: asset) {
            image = cached
            hasFullQualityImage = true
            didFinishPreviewRequest = true
            return
        }
        if requiresFullQuality {
            image = nil
            let requestedImage: UIImage?
            if usesReviewCache {
                requestedImage = await library.prepareReviewPreview(for: asset, allowNetwork: allowNetwork)
            } else {
                requestedImage = await library.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    allowNetwork: allowNetwork,
                    contentMode: contentMode == .fill ? .aspectFill : .aspectFit,
                    deliveryMode: .highQualityFormat
                )
            }
            guard !Task.isCancelled, activeRequestIdentifier == requestIdentifier,
                  requestGeneration == generation else { return }
            image = requestedImage
            hasFullQualityImage = requestedImage != nil
            didFinishPreviewRequest = true
            return
        }
        let useQuickPreview = max(targetSize.width, targetSize.height) >= 900
        image = initialPreview ?? (useQuickPreview ? library.cachedQuickPreview(for: asset) : nil)
        if useQuickPreview, image == nil {
            let quickImage = await library.quickPreview(for: asset)
            guard !Task.isCancelled, activeRequestIdentifier == requestIdentifier,
                  requestGeneration == generation else { return }
            image = quickImage
            if !allowNetwork {
                didFinishPreviewRequest = true
                if quickImage != nil { return }
            }
        }
        if !allowNetwork, image != nil {
            didFinishPreviewRequest = true
            return
        }

        let onDegraded: (@MainActor (UIImage) -> Void)?
        if allowNetwork {
            onDegraded = { preview in
                guard activeRequestIdentifier == requestIdentifier,
                      requestGeneration == generation,
                      !hasFullQualityImage, image == nil else { return }
                image = preview
            }
        } else {
            onDegraded = nil
        }
        let requestedImage = await library.requestImage(
            for: asset,
            targetSize: targetSize,
            allowNetwork: allowNetwork,
            contentMode: contentMode == .fill ? .aspectFill : .aspectFit,
            onDegraded: onDegraded
        )
        guard !Task.isCancelled, activeRequestIdentifier == requestIdentifier,
              requestGeneration == generation else { return }
        if let requestedImage {
            hasFullQualityImage = true
            image = requestedImage
            if usesReviewCache {
                library.cacheReviewPreview(requestedImage, for: asset)
            }
        }
        didFinishPreviewRequest = true
    }

    private var displayedImage: UIImage? {
        if activeRequestIdentifier == asset.localIdentifier, let image { return image }
        if requiresFullQuality, targetSize == CGSize(width: 1_500, height: 1_500),
           let cached = library.cachedReviewPreview(for: asset) { return cached }
        if requiresFullQuality { return nil }
        if let initialPreview { return initialPreview }
        return max(targetSize.width, targetSize.height) >= 900
            ? library.cachedQuickPreview(for: asset) : nil
    }

    private struct ImageRequestIdentity: Equatable {
        let assetID: String
        let allowNetwork: Bool
        let targetSize: CGSize
        let requiresFullQuality: Bool
    }
}

struct AssetPreviewView: View {
    private enum VideoPlaybackState {
        case idle
        case loading
        case manual
        case failed
    }

    let asset: PHAsset
    let library: PhotoLibraryService
    @Binding var videoSoundEnabled: Bool
    var initialPreview: UIImage?
    var requiresFullQuality = false
    var autoplayVideo = false
    var cornerRadius: CGFloat = 28
    var isLivePhotoPressed = false

    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var livePhoto: PHLivePhoto?
    @State private var livePhotoAssetIdentifier: String?
    @State private var livePhotoRequestTask: Task<Void, Never>?
    @State private var livePhotoLoadFailed = false
    @State private var activePlayerIdentifier: String?
    @State private var videoPlaybackTask: Task<Void, Never>?
    @State private var videoPlaybackState: VideoPlaybackState = .idle
    var body: some View {
        Group {
            if asset.mediaType == .video {
                if let player {
                    VideoPlayer(player: player)
                        .onReceive(player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main)) { _ in
                            guard videoSoundEnabled, scenePhase == .active else { return }
                            if player.timeControlStatus == .paused {
                                PreviewAudioSession.stopAudiblePreview(for: asset.localIdentifier)
                            } else if !PreviewAudioSession.beginAudiblePreview(for: asset.localIdentifier) {
                                player.isMuted = true
                                videoSoundEnabled = false
                                PreviewAudioSession.prepareMutedPreview()
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            ZeyingIconButton(
                                systemName: videoSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                accessibilityLabel: videoSoundEnabled ? String(localized: "静音本次审核的视频") : String(localized: "打开本次审核的视频声音"),
                                tint: .white
                            ) {
                                toggleVideoSound(player)
                            }
                            .accessibilityHint(String(localized: "声音设置会用于后续视频，退出审核页后恢复默认静音；用设备音量按钮调整音量"))
                            .padding(16)
                        }
                        .onDisappear { player.pause() }
                } else {
                    ZStack {
                        AssetImageView(
                            asset: asset,
                            library: library,
                            allowNetwork: false,
                            targetSize: CGSize(width: 1_500, height: 1_500),
                            initialPreview: initialPreview,
                            requiresFullQuality: requiresFullQuality
                        )
                        .accessibilityLabel(String(localized: "视频预览"))
                        videoPlaybackOverlay
                    }
                }
            } else {
                AssetImageView(
                    asset: asset,
                    library: library,
                    allowNetwork: settings.iCloudAutoDownloadEnabled,
                    targetSize: CGSize(width: 1_500, height: 1_500),
                    initialPreview: initialPreview,
                    requiresFullQuality: requiresFullQuality
                )
                    .overlay {
                        if livePhotoAssetIdentifier == asset.localIdentifier,
                           let livePhoto {
                            ControlledLivePhotoView(
                                livePhoto: livePhoto,
                                isPlaying: isLivePhotoPressed && scenePhase == .active
                            )
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        if asset.mediaSubtypes.contains(.photoLive), livePhotoLoadFailed {
                            VStack(spacing: 6) {
                                HStack(spacing: 5) {
                                    Image(systemName: "exclamationmark.circle")
                                    Text(String(localized: "实况照片加载失败"))
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.55), in: Capsule())
                                .accessibilityLabel(String(localized: "实况照片暂时无法播放"))

                                Button {
                                    loadLivePhotoIfNeeded()
                                } label: {
                                    Label(String(localized: "重试播放"), systemImage: "arrow.clockwise")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.black.opacity(0.6))
                                .accessibilityLabel(String(localized: "重试播放实况照片"))
                            }
                            .padding(10)
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if asset.mediaSubtypes.contains(.photoLive), !livePhotoLoadFailed {
                            Image(systemName: "livephoto")
                                .accessibilityLabel(String(localized: "实况照片，长按 0.9 秒播放"))
                                .font(.title3.weight(.medium))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.65), radius: 3)
                                .padding(10)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: asset.localIdentifier) {
            let requestIdentifier = asset.localIdentifier
            player?.pause()
            if let activePlayerIdentifier {
                PreviewAudioSession.stopAudiblePreview(for: activePlayerIdentifier)
            }
            player = nil
            activePlayerIdentifier = requestIdentifier
            livePhotoRequestTask?.cancel()
            livePhotoRequestTask = nil
            livePhoto = nil
            livePhotoAssetIdentifier = nil
            livePhotoLoadFailed = false
            videoPlaybackTask?.cancel()
            videoPlaybackTask = nil
            videoPlaybackState = .idle
            if asset.mediaType == .video, autoplayVideo {
                startVideoPlayback(allowNetwork: false)
            }
        }
        .onChange(of: isLivePhotoPressed) { _, isPressed in
            if isPressed {
                loadLivePhotoIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard asset.mediaType == .video else { return }
            if phase == .active {
                if let player {
                    if videoSoundEnabled {
                        if PreviewAudioSession.beginAudiblePreview(for: asset.localIdentifier) {
                            player.isMuted = false
                        } else {
                            videoSoundEnabled = false
                            player.isMuted = true
                            PreviewAudioSession.prepareMutedPreview()
                        }
                    } else {
                        player.isMuted = true
                        PreviewAudioSession.prepareMutedPreview()
                    }
                    player.play()
                }
            } else {
                player?.pause()
                PreviewAudioSession.stopAudiblePreview(for: asset.localIdentifier)
            }
        }
        .onDisappear {
            player?.pause()
            PreviewAudioSession.stopAudiblePreview(for: asset.localIdentifier)
            player = nil
            videoPlaybackTask?.cancel()
            videoPlaybackTask = nil
            videoPlaybackState = .idle
            livePhotoRequestTask?.cancel()
            livePhotoRequestTask = nil
            livePhoto = nil
            livePhotoAssetIdentifier = nil
        }
    }

    private func toggleVideoSound(_ player: AVPlayer) {
        if !videoSoundEnabled {
            if player.timeControlStatus != .paused {
                guard PreviewAudioSession.beginAudiblePreview(for: asset.localIdentifier) else { return }
            }
            player.isMuted = false
            videoSoundEnabled = true
        } else {
            player.isMuted = true
            videoSoundEnabled = false
            PreviewAudioSession.stopAudiblePreview(for: asset.localIdentifier)
            PreviewAudioSession.prepareMutedPreview()
        }
    }

    @ViewBuilder
    private var videoPlaybackOverlay: some View {
        switch videoPlaybackState {
        case .idle:
            if autoplayVideo {
                ProgressView()
                    .tint(.white)
            } else {
                videoPlaybackButton {
                    startVideoPlayback(allowNetwork: true)
                }
            }
        case .manual:
            videoPlaybackButton {
                startVideoPlayback(allowNetwork: true)
            }
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text(String(localized: "正在加载视频…"))
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .failed:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                Text(String(localized: "视频加载失败"))
                    .font(.caption.weight(.medium))
                Button(String(localized: "重试播放")) {
                    startVideoPlayback(allowNetwork: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func videoPlaybackButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(String(localized: "播放视频"), systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.black.opacity(0.62))
        .foregroundStyle(.white)
        .accessibilityLabel(String(localized: "播放视频"))
        .accessibilityHint(String(localized: "点按后尝试载入视频，云端内容可能需要下载"))
    }

    private func startVideoPlayback(allowNetwork: Bool) {
        guard asset.mediaType == .video,
              player == nil,
              videoPlaybackTask == nil else { return }

        let requestIdentifier = asset.localIdentifier
        videoPlaybackState = .loading
        PreviewAudioSession.prepareMutedPreview()
        videoPlaybackTask = Task { @MainActor in
            let item = await library.requestPlayerItem(for: asset, allowNetwork: allowNetwork)
            guard !Task.isCancelled, activePlayerIdentifier == requestIdentifier else { return }
            guard let item else {
                videoPlaybackState = allowNetwork ? .failed : .manual
                videoPlaybackTask = nil
                return
            }

            let previewPlayer = AVPlayer(playerItem: item)
            if videoSoundEnabled, scenePhase == .active {
                if PreviewAudioSession.beginAudiblePreview(for: requestIdentifier) {
                    previewPlayer.isMuted = false
                } else {
                    previewPlayer.isMuted = true
                    videoSoundEnabled = false
                    PreviewAudioSession.prepareMutedPreview()
                }
            } else {
                previewPlayer.isMuted = true
            }
            player = previewPlayer
            videoPlaybackState = .idle
            videoPlaybackTask = nil
            if scenePhase == .active {
                previewPlayer.play()
            }
        }
    }

    private func loadLivePhotoIfNeeded() {
        guard asset.mediaSubtypes.contains(.photoLive),
              livePhotoAssetIdentifier != asset.localIdentifier,
              livePhotoRequestTask == nil else { return }

        livePhotoLoadFailed = false
        let requestIdentifier = asset.localIdentifier
        livePhotoRequestTask = Task {
            let requestedLivePhoto = await library.requestLivePhoto(for: asset, allowNetwork: true)
            guard !Task.isCancelled, activePlayerIdentifier == requestIdentifier else { return }
            livePhoto = requestedLivePhoto
            livePhotoAssetIdentifier = requestedLivePhoto == nil ? nil : requestIdentifier
            livePhotoLoadFailed = requestedLivePhoto == nil
            livePhotoRequestTask = nil
        }
    }
}

@MainActor
private enum PreviewAudioSession {
    private static let logger = Logger(subsystem: "com.mars.zeying", category: "VideoAudio")
    private static var audibleOwner: String?

    static func prepareMutedPreview() {
        if let audibleOwner { stopAudiblePreview(for: audibleOwner) }
        let session = AVAudioSession.sharedInstance()
        guard session.category != .ambient else { return }
        do {
            try session.setCategory(.ambient, mode: .default)
        } catch {
            logger.error("Unable to configure muted video preview: \(error.localizedDescription)")
        }
    }

    static func beginAudiblePreview(for identifier: String) -> Bool {
        if let audibleOwner, audibleOwner != identifier {
            stopAudiblePreview(for: audibleOwner)
        }
        let session = AVAudioSession.sharedInstance()
        if audibleOwner == identifier,
           session.category == .playback,
           !session.categoryOptions.contains(.mixWithOthers) {
            return true
        }
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            audibleOwner = identifier
            return true
        } catch {
            logger.error("Unable to start audible video preview: \(error.localizedDescription)")
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            try? session.setCategory(.ambient, mode: .default)
            return false
        }
    }

    static func stopAudiblePreview(for identifier: String) {
        guard audibleOwner == identifier else { return }
        audibleOwner = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            try session.setCategory(.ambient, mode: .default)
        } catch {
            logger.error("Unable to release video audio session: \(error.localizedDescription)")
        }
    }
}

private struct ControlledLivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let isPlaying: Bool

    func makeUIView(context: Context) -> ReviewLivePhotoView {
        let view = ReviewLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = false
        view.livePhoto = livePhoto
        view.setPlayback(isPlaying)
        return view
    }

    func updateUIView(_ view: ReviewLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
        }
        view.setPlayback(isPlaying)
    }

    static func dismantleUIView(_ view: ReviewLivePhotoView, coordinator: ()) {
        view.setPlayback(false)
    }
}

private final class ReviewLivePhotoView: PHLivePhotoView {
    private var wantsPlayback = false

    func setPlayback(_ isPlaying: Bool) {
        guard wantsPlayback != isPlaying else { return }
        wantsPlayback = isPlaying
        if isPlaying, window != nil, livePhoto != nil {
            startPlayback(with: .full)
        } else if !isPlaying {
            stopPlayback()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopPlayback()
        } else if wantsPlayback, livePhoto != nil {
            startPlayback(with: .full)
        }
    }
}

struct DecisionTapZones: View {
    let isVideo: Bool
    let decisionEnabled: Bool
    var capturesEmptyArea = false
    let onDelete: () -> Void
    let onKeep: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Keep the entire empty area hit-testable for review swipes,
                // including the space above and beside a landscape photo.
                if capturesEmptyArea {
                    Color.clear.contentShape(Rectangle())
                }
                if isVideo {
                    HStack(spacing: 0) {
                        tapZone(action: onDelete)
                            .frame(width: proxy.size.width * 0.24)
                            .padding(.top, 64)
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                        tapZone(action: onKeep)
                            .frame(width: proxy.size.width * 0.24)
                            .padding(.top, 64)
                    }
                } else {
                    HStack(spacing: 0) {
                        tapZone(action: onDelete)
                        tapZone(action: onKeep)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func tapZone(action: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(decisionEnabled)
            .onTapGesture(perform: action)
    }

}

struct AssetSizeCapsule: View {
    let asset: PHAsset
    let sizes: AssetSizeService

    @State private var showingSizeExplanation = false
    @State private var size: Int64?
    @State private var isFetching = false
    @State private var didAttempt = false
    @State private var activeAssetIdentifier: String?
    @State private var explicitSizeTask: Task<Void, Never>?

    private var sizeText: String {
        guard let size else { return didAttempt ? String(localized: "无法获取") : String(localized: "待获取") }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        Button {
            showingSizeExplanation = true
        } label: {
            Text(isFetching ? String(localized: "读取中") : sizeText)
                .font(.caption.weight(.medium).monospacedDigit())
                .frame(minWidth: 54, minHeight: 44)
                .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .disabled(isFetching || size != nil)
        .accessibilityLabel(size == nil ? String(localized: "获取照片文件大小") : String(localized: "照片文件大小 \(sizeText)"))
        .zeyingGlass(in: Capsule())
        .foregroundStyle(.secondary)
        .confirmationDialog(String(localized: "文件大小"), isPresented: $showingSizeExplanation, titleVisibility: .visible) {
            Button(String(localized: "获取大小")) { fetchSize() }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "资源大小不等同于可立即释放的本机空间。如果原片存储在 iCloud，获取大小可能需要下载原片。"))
        }
        .task(id: asset.localIdentifier, priority: .utility) {
            explicitSizeTask?.cancel()
            activeAssetIdentifier = asset.localIdentifier
            size = sizes.knownSize(for: asset)
            didAttempt = false
            isFetching = false
            guard size == nil else { return }
            isFetching = true
            let fetched = await sizes.automaticLocalSize(for: asset)
            guard !Task.isCancelled else { return }
            if let fetched {
                size = fetched
            }
            isFetching = false
        }
        .onDisappear { explicitSizeTask?.cancel() }
    }

    private func fetchSize() {
        guard size == nil else { return }
        isFetching = true
        let identifier = asset.localIdentifier
        explicitSizeTask = Task {
            let fetched = await sizes.fetchSize(for: asset)
            guard !Task.isCancelled, activeAssetIdentifier == identifier else { return }
            size = fetched
            didAttempt = true
            isFetching = false
        }
    }
}

struct AssetInfoView: View {
    let asset: PHAsset
    let sizes: AssetSizeService

    @State private var size: Int64?
    @State private var isFetchingSize = false
    @State private var hasAttemptedSize = false
    @State private var showingSizeExplanation = false
    @State private var activeAssetIdentifier: String?
    @State private var explicitSizeTask: Task<Void, Never>?
    @State private var details: AssetDetailsSnapshot?

    private var dateText: String {
        asset.creationDate?.zeyingDetailedDate ?? String(localized: "日期未知")
    }

    private var dimensionsText: String {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return String(localized: "尺寸未知") }
        return "\(asset.pixelWidth) × \(asset.pixelHeight)"
    }

    private var sizeText: String {
        guard let size else { return hasAttemptedSize ? String(localized: "无法获取") : String(localized: "待获取") }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(String(localized: "照片信息"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(asset.localIdentifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                infoCell(title: String(localized: "类型"), value: asset.mediaType.zeyingTitle)
                infoCell(title: String(localized: "日期"), value: dateText)
                infoCell(title: String(localized: "尺寸"), value: dimensionsText)
                sizeCell
            }

            if let details {
                Divider().padding(.vertical, 4)
                ForEach(details.fields, id: \.title) { field in
                    detailRow(title: field.title, value: field.value)
                }
                if !details.resources.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text(String(localized: "文件资源"))
                        .font(.subheadline.weight(.semibold))
                    ForEach(details.resources, id: \.title) { resource in
                        detailRow(title: resource.title, value: resource.value)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeyingGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .confirmationDialog(String(localized: "文件大小"), isPresented: $showingSizeExplanation, titleVisibility: .visible) {
            Button(String(localized: "获取大小")) { fetchSize() }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "资源大小不等同于可立即释放的本机空间。如果原片存储在 iCloud，获取大小可能需要下载原片。"))
        }
        .onDisappear { explicitSizeTask?.cancel() }
        .task(id: asset.localIdentifier, priority: .utility) {
            details = nil
            let identifier = asset.localIdentifier
            let loaded = await Task.detached(priority: .utility) {
                AssetDetailsSnapshot.load(identifier: identifier)
            }.value
            guard !Task.isCancelled else { return }
            details = loaded
        }
    }

    private func infoCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var sizeCell: some View {
        Button {
            if size == nil { showingSizeExplanation = true }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(String(localized: "文件大小"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if size == nil && !hasAttemptedSize {
                        Image(systemName: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if isFetchingSize {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(sizeText)
                        .font(.footnote.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFetchingSize || size != nil)
        .accessibilityLabel(size == nil ? String(localized: "获取照片文件大小") : String(localized: "照片文件大小 \(sizeText)"))
        .task(id: asset.localIdentifier, priority: .utility) {
            explicitSizeTask?.cancel()
            activeAssetIdentifier = asset.localIdentifier
            size = sizes.knownSize(for: asset)
            hasAttemptedSize = false
            isFetchingSize = false
            guard size == nil else { return }
            isFetchingSize = true
            let fetched = await sizes.automaticLocalSize(for: asset)
            guard !Task.isCancelled else { return }
            if let fetched {
                size = fetched
            }
            isFetchingSize = false
        }
    }

    private func fetchSize() {
        guard size == nil else { return }
        isFetchingSize = true
        let identifier = asset.localIdentifier
        explicitSizeTask = Task {
            let fetched = await sizes.fetchSize(for: asset)
            guard !Task.isCancelled, activeAssetIdentifier == identifier else { return }
            size = fetched
            hasAttemptedSize = true
            isFetchingSize = false
        }
    }
}

private struct AssetDetailField: Sendable {
    let title: String
    let value: String
}

/// Fetches one asset's optional metadata only while its details sheet is open.
/// This work stays off the main actor and never reads image or video bytes.
private struct AssetDetailsSnapshot: Sendable {
    let fields: [AssetDetailField]
    let resources: [AssetDetailField]

    static func load(identifier: String) -> AssetDetailsSnapshot? {
        let options = PHFetchOptions()
        if #available(iOS 27, *) {
            options.prefetchAssetExtendedMetadata = true
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: options).firstObject else {
            return nil
        }

        var fields: [AssetDetailField] = []
        func add(_ title: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(AssetDetailField(title: title, value: value))
        }

        add(String(localized: "加入图库"), asset.addedDate?.zeyingDetailedDate)
        add(String(localized: "最近修改"), asset.modificationDate?.zeyingDetailedDate)
        if asset.mediaType == .video {
            let seconds = Int(asset.duration.rounded())
            let duration = seconds >= 3_600
                ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
            add(String(localized: "时长"), duration)
        }
        if asset.pixelWidth > 0, asset.pixelHeight > 0 {
            let megapixels = Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000
            add(String(localized: "像素"), String(format: "%.1f MP", megapixels))
        }
        add(String(localized: "格式"), asset.contentType.localizedDescription ?? asset.contentType.identifier)

        let subtypeNames: [(PHAssetMediaSubtype, String)] = [
            (.photoLive, String(localized: "实况照片")),
            (.photoPanorama, String(localized: "全景照片")),
            (.photoHDR, String(localized: "HDR 照片")),
            (.photoScreenshot, String(localized: "屏幕截图")),
            (.photoDepthEffect, String(localized: "人像照片")),
            (.photoAnimation, String(localized: "动态图片")),
            (.spatialMedia, String(localized: "空间媒体")),
            (.videoHighFrameRate, String(localized: "慢动作视频")),
            (.videoTimelapse, String(localized: "延时摄影")),
            (.videoScreenRecording, String(localized: "屏幕录制")),
            (.videoCinematic, String(localized: "电影效果")),
            (.videoStreamed, String(localized: "流媒体视频"))
        ]
        let subtypes = subtypeNames.filter { asset.mediaSubtypes.contains($0.0) }.map(\.1)
        add(String(localized: "媒体特征"), subtypes.isEmpty ? nil : subtypes.joined(separator: " · "))

        if asset.playbackVariation != .none {
            let variation: String
            switch asset.playbackVariation {
            case .autoloop: variation = String(localized: "循环播放")
            case .mirror: variation = String(localized: "来回播放")
            case .longExposure: variation = String(localized: "长曝光")
            case .none: variation = ""
            @unknown default: variation = ""
            }
            add(String(localized: "实况效果"), variation)
        }

        var sources: [String] = []
        if asset.sourceType.contains(.typeUserLibrary) { sources.append(String(localized: "个人图库")) }
        if asset.sourceType.contains(.typeCloudShared) { sources.append(String(localized: "共享图库")) }
        if asset.sourceType.contains(PHAssetSourceType(rawValue: 1 << 2)) {
            sources.append(String(localized: "同步到设备"))
        }
        add(String(localized: "来源"), sources.isEmpty ? nil : sources.joined(separator: " · "))
        add(String(localized: "收藏状态"), asset.isFavorite ? String(localized: "已收藏") : String(localized: "未收藏"))
        add(String(localized: "隐藏状态"), asset.isHidden ? String(localized: "已隐藏") : String(localized: "未隐藏"))
        add(String(localized: "编辑状态"), asset.hasAdjustments ? String(localized: "已编辑") : String(localized: "未编辑"))
        add(String(localized: "最近编辑"), asset.adjustmentTimestamp?.zeyingDetailedDate)
        add(String(localized: "连拍编号"), asset.burstIdentifier)

        if let location = asset.location {
            add(String(localized: "位置坐标"), String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude))
            if location.verticalAccuracy >= 0 {
                add(String(localized: "海拔"), String(format: "%.0f m", location.altitude))
            }
        }

        if #available(iOS 27, *) {
            let extra = asset.extendedMetadata
            add(String(localized: "说明"), extra.caption)
            add(String(localized: "关键词"), extra.keywords.isEmpty ? nil : extra.keywords.joined(separator: " · "))
            if asset.rating != .unset {
                add(String(localized: "评分"), "\(asset.rating.rawValue) / 5")
            }
            if asset.originalResourceChoice == .raw {
                add(String(localized: "原始版本"), "RAW")
            }
        }
        add(String(localized: "照片标识"), asset.localIdentifier)

        let resources = PHAssetResource.assetResources(for: asset).enumerated().map { index, resource in
            var parts: [String] = []
            if #available(iOS 27, *), let filename = resource.filename {
                parts.append(filename)
            } else {
                parts.append(resource.originalFilename)
            }
            parts.append(resource.contentType.localizedDescription ?? resource.contentType.identifier)
            if #available(iOS 27, *), let bytes = resource.dataSize {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            return AssetDetailField(
                title: String(localized: "资源 \(index + 1) · \(resource.type.detailTitle)"),
                value: parts.joined(separator: " · ")
            )
        }
        return AssetDetailsSnapshot(fields: fields, resources: resources)
    }
}

private extension PHAssetResourceType {
    var detailTitle: String {
        switch self {
        case .photo: String(localized: "照片文件")
        case .video: String(localized: "视频文件")
        case .audio: String(localized: "音频文件")
        case .alternatePhoto: String(localized: "备用照片")
        case .fullSizePhoto: String(localized: "完整照片")
        case .fullSizeVideo: String(localized: "完整视频")
        case .adjustmentData: String(localized: "编辑数据")
        case .adjustmentBasePhoto: String(localized: "编辑前照片")
        case .pairedVideo: String(localized: "实况视频")
        case .fullSizePairedVideo: String(localized: "完整实况视频")
        case .adjustmentBasePairedVideo: String(localized: "编辑前实况视频")
        case .adjustmentBaseVideo: String(localized: "编辑前视频")
        case .photoProxy: String(localized: "照片预览文件")
        @unknown default: String(localized: "其他文件")
        }
    }
}

struct AssetZoomView: View {
    let asset: PHAsset
    let library: PhotoLibraryService

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var startScale: CGFloat = 1
    @State private var startOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                AssetImageView(
                    asset: asset,
                    library: library,
                    allowNetwork: asset.mediaType == .image && settings.iCloudAutoDownloadEnabled,
                    targetSize: CGSize(width: 2_400, height: 2_400)
                )
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(startScale * value, 1), 4)
                            }
                            .onEnded { _ in
                                startScale = scale
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: startOffset.width + value.translation.width,
                                    height: startOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                startOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        let update = {
                            scale = scale > 1 ? 1 : 2.5
                            offset = .zero
                            startScale = scale
                            startOffset = .zero
                        }
                        if reduceMotion {
                            update()
                        } else {
                            withAnimation(.snappy) {
                                update()
                            }
                        }
                    }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "完成")) { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

}
