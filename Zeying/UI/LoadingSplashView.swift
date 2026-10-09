import SwiftUI

/// The first-load screen keeps PhotoKit work out of the home UI. It is shown
/// only after read access is available; authorization itself remains visible
/// in the regular home screen.
struct LoadingSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LaunchGradientBackground()

            VStack(spacing: 24) {
                VStack(spacing: 9) {
                    Text(String(localized: "择影"))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .tracking(-0.8)

                    Text(String(localized: "正在准备你的图库"))
                        .font(.title3.weight(.semibold))

                    Text(String(localized: "照片和视频很快就会准备好"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .multilineTextAlignment(.center)

                LoadingDots(reduceMotion: reduceMotion, color: .white)
            }
            .foregroundStyle(.white)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "择影正在准备你的图库"))
    }
}

/// Keep navigation inside the library visually continuous while a group is
/// prepared. The launch artwork belongs only to the initial library load.
struct GroupLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            LoadingDots(reduceMotion: reduceMotion, color: .primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(String(localized: "正在准备照片"))
    }
}

/// Kept visually close to the static launch storyboard so the handoff into
/// the first SwiftUI frame feels continuous rather than like a new screen.
private struct LaunchGradientBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.063, green: 0.110, blue: 0.231),
                    Color(red: 0.145, green: 0.125, blue: 0.267),
                    Color(red: 0.267, green: 0.114, blue: 0.247)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.302, green: 0.800, blue: 0.949).opacity(0.78),
                    Color(red: 0.247, green: 0.482, blue: 0.827).opacity(0.30),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.502, blue: 0.416).opacity(0.70),
                    Color(red: 0.910, green: 0.361, blue: 0.600).opacity(0.25),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 470
            )

            RadialGradient(
                colors: [
                    Color(red: 0.663, green: 0.561, blue: 1.0).opacity(0.30),
                    .clear
                ],
                center: UnitPoint(x: 0.63, y: 0.28),
                startRadius: 0,
                endRadius: 360
            )

            LinearGradient(
                colors: [.white.opacity(0.08), .clear, .white.opacity(0.035)],
                startPoint: UnitPoint(x: 0.16, y: 0.08),
                endPoint: UnitPoint(x: 0.82, y: 0.92)
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A quiet, non-rotating progress cue. TimelineView keeps the animation
/// lightweight and lets reduced-motion users see a stable three-dot cue.
struct LoadingDots: View {
    let reduceMotion: Bool
    let color: Color

    var body: some View {
        Group {
            if reduceMotion {
                dots(activeIndex: nil)
            } else {
                TimelineView(.periodic(from: .now, by: 0.52)) { context in
                    let activeIndex = Int(context.date.timeIntervalSinceReferenceDate / 0.52) % 3
                    dots(activeIndex: activeIndex)
                }
            }
        }
        .frame(height: 14)
        .accessibilityLabel(String(localized: "正在读取照片图库"))
    }

    private func dots(activeIndex: Int?) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(color.opacity(activeIndex == index ? 0.95 : 0.38))
                    .frame(width: activeIndex == index ? 13 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.18), value: activeIndex)
            }
        }
        .accessibilityHidden(true)
    }
}
