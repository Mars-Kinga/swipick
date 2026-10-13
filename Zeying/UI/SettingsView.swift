import Photos
import SwiftUI
import UIKit

struct SettingsView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore

    @Environment(AppSettings.self) private var settings
    @Environment(PhotoSuggestionService.self) private var suggestions
    @State private var showingGuide = false
    @State private var showingClearAnalysisConfirmation = false
    @State private var showingClearAnalysisError = false

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            ZeyingRootPageTitle(title: String(localized: "设置"),
                                matchesHomeExpandedPosition: true, usesHomeHeaderHeight: true)

            Form {
                Section {
                    Button {
                        showingGuide = true
                    } label: {
                        Label(String(localized: "查看使用指南"), systemImage: "book.closed")
                    }
                }

                Section {
                    Toggle(isOn: $settings.sideTapDecisionsEnabled) {
                        Label(String(localized: "侧边点按做决定"), systemImage: "hand.tap")
                    }
                    .tint(.blue)
                    .accessibilityHint(String(localized: "开启后，点审核区域左半边加入待删除，点右半边保留；照片周围空白也能点按或滑动。"))

                    Toggle(isOn: $settings.hapticsEnabled) {
                        Label(String(localized: "触觉反馈"), systemImage: "waveform")
                    }
                    .tint(.blue)
                    .accessibilityLabel(String(localized: "触觉反馈"))
                    .accessibilityHint(String(localized: "控制保留、删除和撤销操作时的触觉反馈"))

                    Toggle(isOn: $settings.protectFavoritesEnabled) {
                        Label(String(localized: "保护收藏照片"), systemImage: "checkmark.shield")
                    }
                    .tint(.blue)
                    .accessibilityHint(String(localized: "已收藏或待收藏的照片加入待删除前，再次确认。"))
                } header: {
                    Text(String(localized: "交互"))
                }

                Section {
                    Toggle(isOn: Binding(get: { !suggestions.isManuallyPaused }, set: { enabled in
                        if enabled { suggestions.start(library: library, reviews: reviews) }
                        else { suggestions.pause(manually: true) }
                    })) {
                        Label(String(localized: "自动分析清理建议"), systemImage: "wand.and.stars")
                    }
                    .tint(.blue)
                    .disabled(suggestions.isClearingAnalysisData)

                    Button(role: .destructive) {
                        showingClearAnalysisConfirmation = true
                    } label: {
                        HStack {
                            Label(String(localized: "清除建议分析数据"), systemImage: "trash")
                            if suggestions.isClearingAnalysisData {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(suggestions.isClearingAnalysisData)
                } footer: {
                    Text(String(localized: "清除后会暂停自动分析；再次开启时需要重新分析照片。"))
                }

                Section {
                    Toggle(isOn: $settings.iCloudAutoDownloadEnabled) {
                        Label(String(localized: "自动下载 iCloud 原片"), systemImage: "icloud.and.arrow.down")
                    }
                    .tint(.blue)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text(String(localized: "默认使用缩略图；开启后下载当前原片，可能占用流量和空间。"))
                }

                Section {
                    LabeledContent {
                        Text(authorizationTitle)
                            .foregroundStyle(authorizationTint)
                    } label: {
                        Label(String(localized: "照片访问"), systemImage: "photo.on.rectangle")
                    }

                    Button(action: managePhotoAccess) {
                        Label(photoAccessActionTitle, systemImage: photoAccessActionSymbol)
                    }
                    .accessibilityHint(photoAccessActionHint)
                } header: {
                    Text(String(localized: "照片图库"))
                }

                Section {
                    LabeledContent(String(localized: "版本"), value: appVersion)
                }
            }
            .formStyle(.grouped)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showingGuide) {
            FirstUseGuideView { showingGuide = false }
        }
        .confirmationDialog(String(localized: "清除建议分析数据？"),
                            isPresented: $showingClearAnalysisConfirmation,
                            titleVisibility: .visible) {
            Button(String(localized: "清除建议分析数据"), role: .destructive) {
                Task {
                    do {
                        try await suggestions.clearAnalysisData()
                    } catch {
                        showingClearAnalysisError = true
                    }
                }
            }
        } message: {
            Text(String(localized: "将删除本机生成的建议分析数据。照片、审核决定和清单不受影响。自动分析会暂停；再次开启后需要重新分析照片，可能耗时并消耗电量。"))
        }
        .alert(String(localized: "无法清除建议分析数据"), isPresented: $showingClearAnalysisError) {
            Button(String(localized: "好的"), role: .cancel) {}
        } message: {
            Text(String(localized: "请稍后重试。"))
        }
    }

    private var authorizationTitle: String {
        switch library.authorizationStatus {
        case .authorized:
            return String(localized: "完全访问")
        case .limited:
            return String(localized: "有限访问")
        case .denied:
            return String(localized: "已拒绝")
        case .restricted:
            return String(localized: "受系统限制")
        case .notDetermined:
            return String(localized: "尚未选择")
        @unknown default:
            return String(localized: "不可用")
        }
    }

    private var authorizationTint: Color {
        switch library.authorizationStatus {
        case .authorized:
            return .green
        case .limited:
            return .orange
        case .denied, .restricted:
            return .red
        case .notDetermined:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private var photoAccessActionTitle: String {
        switch library.authorizationStatus {
        case .limited:
            return String(localized: "管理可访问照片")
        case .notDetermined:
            return String(localized: "允许访问照片")
        default:
            return String(localized: "打开系统设置")
        }
    }

    private var photoAccessActionSymbol: String {
        switch library.authorizationStatus {
        case .limited:
            return "checklist.checked"
        case .notDetermined:
            return "lock.open"
        default:
            return "arrow.up.forward.app"
        }
    }

    private var photoAccessActionHint: String {
        switch library.authorizationStatus {
        case .limited:
            return String(localized: "打开系统照片选择器，调整择影可以访问的照片")
        case .notDetermined:
            return String(localized: "请求照片图库访问权限")
        default:
            return String(localized: "打开择影在系统设置中的照片权限页面")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? String(localized: "未知")
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }

    private func managePhotoAccess() {
        switch library.authorizationStatus {
        case .limited:
            ZeyingLimitedLibraryAccess.present(using: library)
        case .notDetermined:
            Task { await library.requestAuthorization() }
        default:
            openAppSettings()
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

struct CleanupStatisticsView: View {
    let reviews: ReviewStore

    var body: some View {
        Form {
            CleanupStatisticsSection(reviews: reviews, showsHeader: false)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: "清理统计"))
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct CleanupStatisticsSection: View {
    let reviews: ReviewStore
    var showsHeader = true

    var body: some View {
        Section {
            LabeledContent {
                Text(String(localized: "\(reviews.cleanupTotals.deletedPhotoCount) 张"))
                    .monospacedDigit()
            } label: {
                Label(String(localized: "已清理照片"), systemImage: "photo")
            }

            LabeledContent {
                Text(String(localized: "\(reviews.cleanupTotals.deletedVideoCount) 个"))
                    .monospacedDigit()
            } label: {
                Label(String(localized: "已清理视频"), systemImage: "video")
            }

            LabeledContent {
                Text(String(localized: "\(LivePhotoConversionManager.shared.convertedCount) 张"))
                    .monospacedDigit()
            } label: {
                Label(String(localized: "已转为静态照片"), systemImage: "livephoto.slash")
            }

            LabeledContent {
                Text(knownDeletedBytesText)
                    .monospacedDigit()
            } label: {
                Label(String(localized: "已知资源大小"), systemImage: "externaldrive")
            }
        } header: {
            if showsHeader {
                Text(String(localized: "清理统计"))
            }
        } footer: {
            if !showsHeader {
                Text(String(localized: "照片与视频清理数只记录确认删除成功的内容；转为静态单独计数。已知资源大小不代表设备会立即释放相同空间。"))
            }
        }
    }

    private var knownDeletedBytesText: String {
        let bytes = reviews.cleanupTotals.knownDeletedBytes
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
