import SwiftUI

/// A short, skippable guide shown once before the first review session.
struct FirstUseGuideView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private let steps: [GuideStep] = [
        GuideStep(
            symbol: "hand.draw",
            tint: .blue,
            title: String(localized: "三种手势，一张张选"),
            intro: String(localized: "选完自动进入下一张；左右两侧也可以点按。"),
            tips: [
                GuideTip(symbol: "arrow.left", title: String(localized: "左滑 · 待删除"),
                         detail: String(localized: "左滑或点照片左侧，可将照片放进待删除清单；确认前不会从系统照片删除。")),
                GuideTip(symbol: "arrow.right", title: String(localized: "右滑 · 保留"),
                         detail: String(localized: "右滑或点照片右侧，可保留当前照片或视频并进入下一张。")),
                GuideTip(symbol: "arrow.down", title: String(localized: "下滑 · 待决定"),
                         detail: String(localized: "明显向下滑并松手才生效；短滑或斜滑会回弹。"))
            ]
        ),
        GuideStep(
            symbol: "square.stack.3d.up",
            tint: .mint,
            title: String(localized: "按自己的方式整理"),
            intro: String(localized: "首页先选一组，随时回来继续。"),
            tips: [
                GuideTip(symbol: "calendar", title: String(localized: "月份、类型、相簿"),
                         detail: String(localized: "可按月、按年、类型或相簿进入；已处理照片也能往回查看。")),
                GuideTip(symbol: "arrow.right.circle", title: String(localized: "继续清理"),
                         detail: String(localized: "若上次那组还有未处理内容，会从那里继续。")),
                GuideTip(symbol: "shuffle", title: String(localized: "随机清理"),
                         detail: String(localized: "首页可随机开始；审核页返回键旁可打乱本组剩余顺序。")),
                GuideTip(symbol: "rectangle.stack.badge.plus", title: String(localized: "相簿整理"),
                         detail: String(localized: "照片上方可选相簿；待加入的相簿再点一次可取消。勾号表示已加入系统相簿，点它可移除，照片仍留在图库。"))
            ]
        ),
        GuideStep(
            symbol: "photo.on.rectangle.angled",
            tint: .purple,
            title: String(localized: "照片和视频这样看"),
            intro: String(localized: "看清内容后再决定。"),
            tips: [
                GuideTip(symbol: "plus.magnifyingglass", title: String(localized: "放大照片"),
                         detail: String(localized: "双指放大，放大后拖动查看细节。")),
                GuideTip(symbol: "livephoto.slash", title: String(localized: "转为静态照片"),
                         detail: String(localized: "点右上角带斜杠的 Live 图标创建静态照片。原拍摄时间不变，但“最近添加”会按新加入时间排序，位置可能与原照片不同。随后由 iOS 确认是否删除原件。")),
                GuideTip(symbol: "speaker.slash", title: String(localized: "视频声音"),
                         detail: String(localized: "视频默认静音；点扬声器后，本次审核的视频会沿用声音设置。")),
                GuideTip(symbol: "info.circle", title: String(localized: "详情与分享"),
                         detail: String(localized: "右上角可查看日期、尺寸和文件大小，也可以调用系统分享。"))
            ]
        ),
        GuideStep(
            symbol: "checklist",
            tint: .blue,
            title: String(localized: "最后到清单确认"),
            intro: String(localized: "默认先做决定，再分别提交到系统照片。"),
            tips: [
                GuideTip(symbol: "trash", title: String(localized: "删除全部"),
                         detail: String(localized: "待删除照片在清单里统一确认；系统可能再次提示。")),
                GuideTip(symbol: "arrow.uturn.backward", title: String(localized: "不想删了"),
                         detail: String(localized: "点单张“恢复”或“恢复全部”，照片就会改为保留。")),
                GuideTip(symbol: "star", title: String(localized: "收藏与相簿"),
                         detail: String(localized: "收藏和已有相簿的整理会先暂存，再到清单分别确认。")),
                GuideTip(symbol: "checkmark.shield", title: String(localized: "系统还会确认"),
                         detail: String(localized: "在清单批量提交删除时，iOS 会再次显示系统确认。"))
            ]
        ),
        GuideStep(
            symbol: "arrow.uturn.backward",
            tint: .orange,
            title: String(localized: "点错了，随时改"),
            intro: String(localized: "默认暂存时，可以撤销或重新选择。"),
            tips: [
                GuideTip(symbol: "arrow.uturn.backward", title: String(localized: "撤销上一张"),
                         detail: String(localized: "点审核页的回转箭头，回到刚才那张。")),
                GuideTip(symbol: "questionmark.circle", title: String(localized: "待决定单独放"),
                         detail: String(localized: "到下方“待决定”页，可重新选择保留或删除。")),
                GuideTip(symbol: "star", title: String(localized: "收藏也先暂存"),
                         detail: String(localized: "未收藏的照片点星星会保留并暂存收藏，清单确认后再同步。")),
                GuideTip(symbol: "star.fill", title: String(localized: "实心星星"),
                         detail: String(localized: "表示系统照片已收藏；点按并确认可取消收藏，照片不会删除。"))
            ]
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
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

            TabView(selection: $page) {
                ForEach(steps.indices, id: \.self) { index in
                    guidePage(steps[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            Button {
                if page == steps.count - 1 {
                    onFinish()
                } else if reduceMotion {
                    page += 1
                } else {
                    withAnimation(.snappy(duration: 0.24)) { page += 1 }
                }
            } label: {
                Text(page == steps.count - 1 ? String(localized: "开始整理") : String(localized: "下一步"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(ZeyingGlassButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityLabel(String(localized: "择影使用指南"))
    }

    private func guidePage(_ step: GuideStep) -> some View {
        ScrollView {
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
                    Text(step.intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(step.tips.indices, id: \.self) { index in
                        if index > 0 { Divider() }
                        guideTip(step.tips[index], tint: step.tint)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
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
    let intro: String
    let tips: [GuideTip]
}

private struct GuideTip {
    let symbol: String
    let title: String
    let detail: String
}
