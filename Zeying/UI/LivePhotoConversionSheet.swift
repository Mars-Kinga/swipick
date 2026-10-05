import Photos
import SwiftUI
import UIKit

struct LivePhotoConversionSheet: View {
    let sourceIdentifier: String
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let albumAssignments: PendingAlbumAssignmentStore
    var initialPreview: UIImage? = nil
    var onFinished: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isBusy = false
    @State private var operationPreviewAsset: PHAsset?
    @State private var progressMessage: String?
    @State private var errorMessage: String?
    @State private var showingCancelConfirmation = false

    private let conversions = LivePhotoConversionManager.shared

    private var record: LivePhotoConversion? {
        conversions.conversion(for: sourceIdentifier)
    }

    private var source: PHAsset? {
        library.asset(with: sourceIdentifier)
    }

    private var still: PHAsset? {
        guard let identifier = record?.stillIdentifier else { return nil }
        return library.asset(with: identifier)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction

                    if isBusy, let operationPreviewAsset {
                        // Keep the visible image stable while Photos imports
                        // the copy and presents its own deletion confirmation.
                        preview(operationPreviewAsset)
                    } else if let still {
                        preview(still)
                        replacementActions
                    } else if record?.phase == .originalDeleted {
                        replacementActions
                    } else {
                        if let source {
                            preview(source)
                        }
                        preparationAction
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(String(localized: "转为静态照片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(record == nil ? String(localized: "关闭") : String(localized: "稍后继续")) { dismiss() }
                        .disabled(isBusy)
                }
            }
            .interactiveDismissDisabled(isBusy)
            .confirmationDialog(
                String(localized: "取消这次转换？"),
                isPresented: $showingCancelConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "删除静态副本，保留原件"), role: .destructive) {
                    Task { await deleteStillCopy() }
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "系统可能再次要求确认。原实况照片会保留。"))
            }
            .alert(String(localized: "操作未完成"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "知道了")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? String(localized: "请稍后重试。"))
            }
            .task {
                if record != nil {
                    if still == nil || source == nil {
                        await library.refresh()
                    }
                    if record?.phase == .preparing, source != nil {
                        await prepareCopy(continueToDeletion: false)
                    }
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "保留这一帧"), systemImage: "livephoto.slash")
                .font(.title2.weight(.semibold))
            Text(record?.phase == .originalDeleted
                 ? String(localized: "原实况照片已删除，静态照片已保留。完成本地记录后即可继续整理。")
                 : record?.phase == .awaitingOriginalDeletion
                   ? String(localized: "静态照片已准备好。继续后，iOS 会确认是否删除原实况照片。")
                   : String(localized: "创建静态照片并核对拍摄时间与相簿，然后由 iOS 确认删除原实况照片。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let progressMessage {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progressMessage)
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityElement(children: .combine)
            } else if record?.phase == .awaitingOriginalDeletion {
                Label(String(localized: "静态副本已创建，原件仍在图库中"), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized {
                Label(String(localized: "安全转换需要完整照片访问权限，以核对原相簿。"), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(String(localized: "打开系统设置")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeyingGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func preview(_ asset: PHAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(asset.localIdentifier == sourceIdentifier ? String(localized: "原实况照片") : String(localized: "新静态照片"))
                .font(.subheadline.weight(.semibold))
            AssetImageView(
                asset: asset,
                library: library,
                allowNetwork: false,
                targetSize: CGSize(width: 1_000, height: 1_000),
                initialPreview: asset.localIdentifier == sourceIdentifier ? initialPreview : nil
            )
            .frame(maxWidth: .infinity)
            .frame(height: 330)
            .background(.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)

            Text(String(localized: "拍摄时间：\(asset.creationDate?.zeyingDetailedDate ?? String(localized: "未知"))"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var preparationAction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await prepareCopy(continueToDeletion: true) }
            } label: {
                Label(record == nil ? String(localized: "转为静态照片") : String(localized: "重新尝试转换"), systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(isBusy || source == nil ||
                      PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized)

            Text(String(localized: "照片会保留原拍摄时间和相簿；动态片段不会保留。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var replacementActions: some View {
        VStack(spacing: 12) {
            Button {
                Task { await deleteOriginal() }
            } label: {
                Label(record?.phase == .originalDeleted ? String(localized: "完成本地记录") :
                      source == nil ? String(localized: "完成转换") : String(localized: "删除原件并完成转换"),
                      systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(isBusy || still == nil)

            if record?.phase != .originalDeleted, source != nil {
                Button {
                    showingCancelConfirmation = true
                } label: {
                    Label(String(localized: "取消转换，删除静态副本"), systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ZeyingGlassButtonStyle(tint: .red))
                .disabled(isBusy)
            }

            Text(String(localized: "静态照片已自动核对。新照片不包含动态片段和编辑历史；“最近添加”会显示为今天。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func prepareCopy(continueToDeletion: Bool) async {
        guard let source else { return }
        operationPreviewAsset = source
        isBusy = true
        progressMessage = String(localized: "正在创建静态照片…")
        do {
            _ = try await conversions.prepare(asset: source, library: library)
            if continueToDeletion {
                progressMessage = String(localized: "请在 iOS 中确认删除原件…")
                try await conversions.deleteOriginal(
                    sourceIdentifier: sourceIdentifier,
                    library: library,
                    reviews: reviews,
                    albumAssignments: albumAssignments
                )
                dismiss()
                onFinished?()
            } else {
                await library.refresh()
            }
        } catch {
            // A failed or declined system deletion leaves the verified still
            // and the original intact. Show the copy so deletion can be retried.
            if record?.stillIdentifier != nil { await library.refresh() }
            errorMessage = error.localizedDescription
        }
        progressMessage = nil
        isBusy = false
        operationPreviewAsset = nil
    }

    private func deleteOriginal() async {
        operationPreviewAsset = still ?? source
        isBusy = true
        progressMessage = String(localized: "请在 iOS 中确认删除原件…")
        do {
            try await conversions.deleteOriginal(
                sourceIdentifier: sourceIdentifier,
                library: library,
                reviews: reviews,
                albumAssignments: albumAssignments
            )
            dismiss()
            onFinished?()
        } catch {
            errorMessage = error.localizedDescription
        }
        progressMessage = nil
        isBusy = false
        operationPreviewAsset = nil
    }

    private func deleteStillCopy() async {
        operationPreviewAsset = still
        isBusy = true
        progressMessage = String(localized: "正在删除静态副本…")
        do {
            try await conversions.deleteStillCopy(sourceIdentifier: sourceIdentifier, library: library)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        progressMessage = nil
        isBusy = false
        operationPreviewAsset = nil
    }
}
