import SwiftUI
import UIKit

/// A short, skippable guide shown once before the first review session.
struct FirstUseGuideView: View {
    var compact = false
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var page = 0

    private let steps: [GuideStep] = [
        GuideStep(
            symbol: "hand.draw",
            tint: .blue,
            title: String(localized: "三种手势，一张张选"),
            intro: String(localized: "用下方按钮或滑动做决定，也可在设置开启更方便的侧边点按。iCloud 照片默认使用缩略图。"),
            tips: [
                GuideTip(symbol: "arrow.left", title: String(localized: "左滑 · 待删除"),
                         detail: String(localized: "确认前不会从系统照片删除。")),
                GuideTip(symbol: "arrow.right", title: String(localized: "右滑 · 保留"),
                         detail: String(localized: "右滑或点“保留”，保留照片或视频并进入下一项。")),
                GuideTip(symbol: "arrow.down", title: String(localized: "下滑 · 待决定"),
                         detail: String(localized: "向下滑动，留到稍后再决定。"))
            ]
        ),
        GuideStep(
            symbol: "photo.on.rectangle.angled",
            tint: .purple,
            title: String(localized: "照片和视频这样处理"),
            intro: nil,
            tips: [
                GuideTip(symbol: "plus.magnifyingglass", title: String(localized: "放大照片"),
                         detail: String(localized: "双指放大查看细节，放大后可拖动。长按播放实况照片。")),
                GuideTip(symbol: "questionmark.circle", title: String(localized: "待决定"),
                         detail: String(localized: "还没想好时，可下滑放入“待决定”；之后从首页打开，再选择保留或删除。")),
                GuideTip(symbol: "livephoto.slash", title: String(localized: "转为静态照片"),
                         detail: String(localized: "创建静态照片后，原实况照片会进入清单等待删除确认。拍摄时间不变，但“最近添加”位置会改变。")),
                GuideTip(symbol: "rectangle.stack.badge.plus", title: String(localized: "相簿整理"),
                         detail: String(localized: "照片上方可选相簿；待加入的相簿再点一次可取消。")),
                GuideTip(symbol: "speaker.slash", title: String(localized: "视频声音"),
                         detail: String(localized: "视频默认静音；点按视频，再点扬声器开启声音。")),
                GuideTip(symbol: "info.circle", title: String(localized: "详情与分享"),
                         detail: String(localized: "右上角可查看日期、尺寸和文件大小，也可以随时分享。"))
            ]
        ),
        GuideStep(
            symbol: "wand.and.stars",
            tint: .indigo,
            title: String(localized: "清理建议"),
            intro: String(localized: "从首页或底部导航进入。应用会自动在本机分析建议，可在设置关闭。"),
            tips: [
                GuideTip(symbol: "square.on.square", title: String(localized: "按组查看"),
                         detail: String(localized: "相似照片、原始文件完全相同的副本，以及超过 90 天的临时截图会分组呈现。")),
                GuideTip(symbol: "checkmark.circle", title: String(localized: "建议由你决定"),
                         detail: String(localized: "相似组可以选择保留一张或多张；建议不会自动删除照片。")),
                GuideTip(symbol: "plus.magnifyingglass", title: String(localized: "大图比较"),
                         detail: String(localized: "点照片打开大图，左右切换比较，双指放大查看细节。"))
            ]
        ),
        GuideStep(
            symbol: "checklist",
            tint: .blue,
            title: String(localized: "最后到清单确认"),
            intro: String(localized: "默认先做决定，再分别提交到系统照片。"),
            tips: [
                GuideTip(symbol: "trash", title: String(localized: "删除全部"),
                         detail: String(localized: "待删除照片在清单里统一确认。")),
                GuideTip(symbol: "arrow.uturn.backward", title: String(localized: "不想删了"),
                         detail: String(localized: "点单张“恢复”或“恢复全部”，即可取消待删除决定。")),
                GuideTip(symbol: "star", title: String(localized: "收藏与相簿"),
                         detail: String(localized: "收藏和已有相簿的整理会先暂存，再到清单分别确认。")),
                GuideTip(symbol: "checkmark.shield", title: String(localized: "系统再次确认"),
                         detail: String(localized: "在清单批量提交删除时，iOS 会再次显示系统确认。"))
            ]
        ),
        GuideStep(
            symbol: "icloud",
            tint: .blue,
            title: String(localized: "iCloud 照片预览"),
            intro: String(localized: "iCloud 照片默认使用缩略图，不自动下载原片。"),
            tips: [
                GuideTip(symbol: "photo", title: String(localized: "先看清，再决定"),
                         detail: String(localized: "仅存于 iCloud 的照片会先显示设备可取得的预览，可能较模糊。")),
                GuideTip(symbol: "gearshape", title: String(localized: "需要高清时再开启"),
                         detail: String(localized: "到“设置”开启“自动下载 iCloud 原片”，正在查看的照片才会自动加载高清内容；可能消耗流量和设备空间。")),
                GuideTip(symbol: "play.circle", title: String(localized: "播放与导出按需加载"),
                         detail: String(localized: "即使关闭自动下载，主动播放视频或实况、分享、转为静态照片时，仍可能下载所需内容。"))
            ]
        )
    ]

    private var guideSteps: [GuideStep] {
        compact ? [steps[0], steps[3], steps[4]] : steps
    }

    private var usesExpandedGuideLayout: Bool {
        (horizontalSizeClass == .regular || verticalSizeClass == .compact) &&
            !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        GeometryReader { geometry in
            let cameraFrame: CGRect? = {
                guard #available(iOS 27.1, *),
                      UIDevice.current.userInterfaceIdiom == .phone,
                      geometry.size.height > geometry.size.width else { return nil }
                return geometry.reservedRegions(kind: .occlusion)
                    .first { $0.isActive && $0.frame.midX > geometry.size.width / 2 &&
                        $0.frame.minY < geometry.size.height / 4 }?.frame
            }()
            let hasExpandedFold: Bool = {
                guard #available(iOS 27.1, *),
                      UIDevice.current.userInterfaceIdiom == .phone,
                      geometry.size.width > geometry.size.height else { return false }
                return geometry.reservedRegions(kind: .division, options: .includeInactive)
                    .contains { $0.frame.minX > 0 && $0.frame.maxX < geometry.size.width }
            }()
            let expandedStatusColumnX = geometry.size.width + geometry.safeAreaInsets.trailing - 47

            VStack(spacing: 0) {
                if usesExpandedGuideLayout {
                    Color.clear.frame(height: 24)
                } else if let cameraFrame {
                    Text(String(localized: "择影"))
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 44)
                        .padding(.horizontal, 24)
                        .padding(.top, max(0, cameraFrame.midY - 22))
                } else {
                    HStack {
                        Text(String(localized: "择影"))
                            .font(.title2.weight(.bold))
                        Spacer()
                        Button(String(localized: "跳过"), action: onFinish)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHint(String(localized: "关闭使用指南"))
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                }

                TabView(selection: $page) {
                    ForEach(guideSteps.indices, id: \.self) { index in
                        guidePage(guideSteps[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                if usesExpandedGuideLayout {
                    ZeyingFoldAwareSplit {
                        Color.clear
                    } trailing: {
                        guideFooter
                    }
                    .frame(height: page == guideSteps.count - 1 ? 148 : 104)
                    .padding(.bottom, 8)
                } else {
                    guideFooter
                        .frame(width: cameraFrame == nil ? nil : geometry.size.width)
                        .offset(x: cameraFrame == nil ? 0 : geometry.safeAreaInsets.trailing / 2)
                        .padding(.bottom, 24)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .overlay(alignment: .topTrailing) {
                if usesExpandedGuideLayout {
                    Button(String(localized: "跳过"), action: onFinish)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .position(
                            x: hasExpandedFold
                                ? expandedStatusColumnX
                                : geometry.size.width - 46,
                            y: hasExpandedFold ? 128 : 54
                        )
                        .accessibilityHint(String(localized: "关闭使用指南"))
                } else if let cameraFrame {
                    Button(String(localized: "跳过"), action: onFinish)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .position(x: cameraFrame.midX, y: cameraFrame.maxY + 112)
                        .accessibilityHint(String(localized: "关闭使用指南"))
                }
            }
            .accessibilityLabel(String(localized: "择影使用指南"))
        }
    }

    private func guidePage(_ step: GuideStep) -> some View {
        Group {
            if usesExpandedGuideLayout {
                ZeyingFoldAwareSplit {
                    ScrollView {
                        guideIntroduction(step)
                            .padding(.horizontal, 24)
                            .padding(.top, 28)
                    }
                    .scrollIndicators(.hidden)
                } trailing: {
                    ScrollView {
                        guideTips(step)
                            .padding(.horizontal, 24)
                            .padding(.top, 28)
                    }
                    .scrollIndicators(.hidden)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        guideIntroduction(step)
                        guideTips(step)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .clipped()
    }

    private var guideFooter: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(guideSteps.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: String(localized: "使用指南，第 %d 页，共 %d 页"), page + 1, guideSteps.count))

            if page == guideSteps.count - 1 {
                Text(String(localized: "之后也可以在设置里再次查看说明指南。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
            }

            Button {
                if page == guideSteps.count - 1 {
                    onFinish()
                } else if reduceMotion {
                    page += 1
                } else {
                    withAnimation(.snappy(duration: 0.24)) { page += 1 }
                }
            } label: {
                Text(page == guideSteps.count - 1 ? String(localized: "开始整理") : String(localized: "下一步"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(ZeyingGlassButtonStyle())
            .padding(.bottom, verticalSizeClass == .compact ? 8 : 0)
        }
        .frame(maxWidth: usesExpandedGuideLayout ? 360 : .infinity)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
    }

    private func guideIntroduction(_ step: GuideStep) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: step.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(step.tint)
                .frame(width: 72, height: 72)
                .background(step.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(step.title)
                    .font(.title.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if let intro = step.intro {
                    Text(intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func guideTips(_ step: GuideStep) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(step.tips.indices, id: \.self) { index in
                if index > 0 { Divider() }
                guideTip(step.tips[index], tint: step.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func guideTip(_ tip: GuideTip, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tip.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 27, height: 27)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(tip.title)
                    .font(.subheadline.weight(.semibold))
                Text(tip.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct GuideStep {
    let symbol: String
    let tint: Color
    let title: String
    let intro: String?
    let tips: [GuideTip]
}

private struct GuideTip {
    let symbol: String
    let title: String
    let detail: String
}
