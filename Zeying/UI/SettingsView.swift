import Photos
import SwiftUI
import UIKit

struct SettingsView: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore

    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingGuide = false

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            ZeyingRootPageTitle(title: String(localized: "设置"))

            Form {
                Section {
                    Button {
                        showingGuide = true
                    } label: {
                        Label(String(localized: "查看使用指南"), systemImage: "book.closed")
                    }
                }

                Section {
                    Toggle(isOn: $settings.hapticsEnabled) {
                        Label {
                            Text(String(localized: "触觉反馈"))
                        } icon: {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tint)
                        }
                    }
                    .accessibilityLabel(String(localized: "触觉反馈"))
                    .accessibilityHint(String(localized: "控制保留、删除和撤销操作时的触觉反馈"))
                } header: {
                    Text(String(localized: "交互"))
                } footer: {
                    Text(String(localized: "关闭后，择影仍会保留视觉反馈和动画。"))
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
                } footer: {
                    Text(photoAccessFooter)
                }

                CleanupStatisticsSection(reviews: reviews)

                Section {
                    LabeledContent(String(localized: "版本"), value: appVersion)
                } footer: {
                    Text(String(localized: "择影"))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await library.refresh() }
        }
        .fullScreenCover(isPresented: $showingGuide) {
            FirstUseGuideView { showingGuide = false }
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

    private var photoAccessFooter: String {
        switch library.authorizationStatus {
        case .authorized:
            return String(localized: "择影可以读取你图库中的照片，并在你确认后执行收藏或删除。")
        case .limited:
            return String(localized: "择影只会读取当前获准访问的照片。")
        case .notDetermined:
            return String(localized: "允许访问后，择影才能读取和整理照片。")
        default:
            return String(localized: "请在系统设置中重新打开照片访问权限。")
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
            Text(String(localized: "照片与视频清理数只记录确认删除成功的内容；转为静态单独计数。已知资源大小不代表设备会立即释放相同空间。"))
        }
    }

    private var knownDeletedBytesText: String {
        let bytes = reviews.cleanupTotals.knownDeletedBytes
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
