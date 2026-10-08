import SwiftUI
import Photos
import PhotosUI
import UIKit

/// Shared visual language for the app. Glass is kept on the control layer so
/// photos remain readable and are never washed out by a material overlay.
extension View {
    @ViewBuilder
    func zeyingGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

struct ZeyingGlassButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        ZeyingGlassButtonContent(
            label: AnyView(configuration.label),
            tint: tint,
            isPressed: configuration.isPressed
        )
    }
}

private struct ZeyingGlassButtonContent: View {
    let label: AnyView
    let tint: Color
    let isPressed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
            .zeyingGlass(in: Capsule())
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.96 : 1))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isPressed)
    }
}

enum ZeyingLimitedLibraryAccess {
    @MainActor
    static func present(using library: PhotoLibraryService) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows
                .first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }

        PHPhotoLibrary.shared().presentLimitedLibraryPicker(
            from: topViewController(from: rootViewController)
        )

        // PhotoKit normally notifies the library service after the picker
        // closes. This delayed refresh also covers systems that omit it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await library.refresh()
        }
    }

    @MainActor
    private static func topViewController(from viewController: UIViewController) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigationController = viewController as? UINavigationController,
           let visible = navigationController.visibleViewController {
            return topViewController(from: visible)
        }
        if let tabBarController = viewController as? UITabBarController,
           let selected = tabBarController.selectedViewController {
            return topViewController(from: selected)
        }
        return viewController
    }
}

struct ZeyingIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .contentShape(Circle())
        .zeyingGlass(in: Circle())
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }
}

struct ZeyingEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ZeyingGlassButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct ZeyingRootPageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    func zeyingAlignedGroupedSectionHeader() -> some View {
        // Inset-grouped headers sit farther in than both the page title and
        // the rounded rows. Use the same outer edge for all three.
        padding(.horizontal, -16)
    }
}

extension Date {
    var zeyingYearTitle: String {
        formatted(.dateTime.year().locale(zeyingDisplayLocale))
    }

    var zeyingMonthTitle: String {
        formatted(.dateTime.year().month(.wide).locale(zeyingDisplayLocale))
    }

    var zeyingHomeMonthTitle: String {
        if Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true {
            return zeyingMonthTitle
        }
        return formatted(.dateTime.month(.abbreviated).year(.twoDigits).locale(zeyingDisplayLocale))
    }

    var zeyingShortDate: String {
        formatted(.dateTime.year().month().day().locale(zeyingDisplayLocale))
    }

    var zeyingDetailedDate: String {
        formatted(.dateTime.year().month().day().hour().minute().locale(zeyingDisplayLocale))
    }
}

private let zeyingDisplayLocale: Locale = {
    let localization = Bundle.main.preferredLocalizations.first ?? "en"
    let current = Locale.current
    if current.language.languageCode?.identifier == Locale(identifier: localization).language.languageCode?.identifier {
        return current
    }
    return Locale(identifier: localization)
}()

extension PHAssetMediaType {
    var zeyingTitle: String {
        switch self {
        case .image: String(localized: "照片")
        case .video: String(localized: "视频")
        case .audio: String(localized: "音频")
        case .unknown: String(localized: "媒体")
        @unknown default: String(localized: "媒体")
        }
    }
}
