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
    @State private var operationTask: Task<Void, Never>?
    @State private var canCancelPreparation = false

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
                        // and verifies the still copy.
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
                    if canCancelPreparation {
                        Button(String(localized: "取消")) {
                            operationTask?.cancel()
                        }
                    } else {
                        Button(record == nil ? String(localized: "关闭") : String(localized: "稍后继续")) { dismiss() }
                            .disabled(isBusy)
                    }
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
                    if let record,
                       source != nil,
                       (record.phase == .preparing ||
                        (record.stillIdentifier != nil && record.verification != .verified)) {
                        let task = Task { await prepareCopy(stageForDeletion: false) }
                        operationTask = task
                        await task.value
                    }
                }
            }
            .onAppear {
                if record == nil, let source {
                    conversions.prewarmStill(for: source)
                }
            }
            .onDisappear {
                operationTask?.cancel()
                conversions.cancelPrewarm(for: sourceIdentifier)
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "保留这一帧"), systemImage: "livephoto.slash")
                .font(.title2.weight(.semibold))
            Text(record?.phase == .originalDeleted
                 ? String(localized: "原实况照片已删除，静态照片已保留。")
                 : record?.verification == .verified
                   ? String(localized: "静态照片已就绪。原件仍在图库中，可加入清单稍后删除。")
                 : record?.verification == .failed
                   ? String(localized: "静态照片未通过核对，原实况照片仍在图库中。")
                 : record?.stillIdentifier != nil
                   ? String(localized: "正在核对静态照片，原件仍在图库中。")
                   : String(localized: "创建并核对静态照片后，原实况照片会加入清单等待删除确认。"))
                .font(.body)
                .foregroundStyle(.secondary)
            if let progressMessage {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progressMessage)
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityElement(children: .combine)
            }
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized {
                Label(String(localized: "安全转换需要完整照片访问权限，以核对原相簿。"), systemImage: "lock.shield")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Button(String(localized: "打开系统设置")) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        }
    }

    private var preparationAction: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "保留拍摄时间和相簿"), systemImage: "checkmark.circle")
                Label(String(localized: "不保留动态片段和编辑历史"), systemImage: "livephoto.slash")
                Label(String(localized: "在“最近添加”中按新导入时间排列"), systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Button {
                launchPreparation(stageForDeletion: true)
            } label: {
                Label(record == nil ? String(localized: "转为静态照片") : String(localized: "重新尝试转换"), systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .disabled(isBusy || source == nil ||
                      PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized)
        }
    }

    private var replacementActions: some View {
        VStack(spacing: 12) {
            if record?.verification == .failed, source != nil {
                Button(String(localized: "重新核对静态照片"), systemImage: "arrow.clockwise") {
                    launchPreparation(stageForDeletion: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .disabled(isBusy)
            } else {
                Button {
                    if record?.phase == .originalDeleted || source == nil {
                        launchDeleteOriginal()
                    } else {
                        launchStageOriginal()
                    }
                } label: {
                    Label(record?.phase == .originalDeleted ? String(localized: "完成本地记录") :
                          source == nil ? String(localized: "完成转换") : String(localized: "原实况照片加入待删除"),
                          systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .disabled(isBusy || still == nil || (record?.verification != .verified && source != nil))
            }

            if record?.phase != .originalDeleted, source != nil {
                Button {
                    showingCancelConfirmation = true
                } label: {
                    Label(String(localized: "取消转换，删除静态副本"), systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
                .disabled(isBusy)
            }
        }
    }

    private func prepareCopy(stageForDeletion: Bool) async {
        guard let source else { return }
        operationPreviewAsset = source
        isBusy = true
        canCancelPreparation = true
        progressMessage = String(localized: "正在创建静态照片…")
        do {
            _ = try await conversions.prepare(asset: source, library: library)
            // Once PhotoKit has created the copy, keep the task alive long
            // enough for the manager to persist its identifier. Cancellation
            // here leaves the verified copy in the journal for a later retry.
            try Task.checkCancellation()
            canCancelPreparation = false
            if stageForDeletion {
                progressMessage = String(localized: "正在加入待删除清单…")
                try Task.checkCancellation()
                try conversions.stageOriginalForDeletion(
                    sourceIdentifier: sourceIdentifier,
                    reviews: reviews
                )
                dismiss()
                onFinished?()
            } else {
                await library.refresh()
            }
        } catch is CancellationError {
            if conversions.conversion(for: sourceIdentifier)?.stillIdentifier != nil {
                await library.refresh()
            }
        } catch {
            // Keep both assets available after a failed preparation or staging.
            if record?.stillIdentifier != nil { await library.refresh() }
            errorMessage = PhotosFailureMessage.message(for: error)
        }
        progressMessage = nil
        isBusy = false
        canCancelPreparation = false
        operationPreviewAsset = nil
    }

    private func deleteOriginal() async {
        operationPreviewAsset = still ?? source
        isBusy = true
        progressMessage = String(localized: "正在完成转换…")
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
            errorMessage = PhotosFailureMessage.message(for: error)
        }
        progressMessage = nil
        isBusy = false
        operationPreviewAsset = nil
    }

    private func stageOriginal() {
        isBusy = true
        progressMessage = String(localized: "正在加入待删除清单…")
        do {
            try conversions.stageOriginalForDeletion(
                sourceIdentifier: sourceIdentifier,
                reviews: reviews
            )
            dismiss()
            onFinished?()
        } catch {
            errorMessage = PhotosFailureMessage.message(for: error)
        }
        progressMessage = nil
        isBusy = false
    }

    private func deleteStillCopy() async {
        operationPreviewAsset = still
        isBusy = true
        progressMessage = String(localized: "正在删除静态副本…")
        do {
            try await conversions.deleteStillCopy(
                sourceIdentifier: sourceIdentifier, library: library, reviews: reviews
            )
            dismiss()
        } catch {
            errorMessage = PhotosFailureMessage.message(for: error)
        }
        progressMessage = nil
        isBusy = false
        operationPreviewAsset = nil
    }

    private func launchPreparation(stageForDeletion: Bool) {
        operationTask?.cancel()
        operationTask = Task { await prepareCopy(stageForDeletion: stageForDeletion) }
    }

    private func launchDeleteOriginal() {
        operationTask?.cancel()
        operationTask = Task { await deleteOriginal() }
    }

    private func launchStageOriginal() {
        operationTask?.cancel()
        operationTask = Task { stageOriginal() }
    }

}
