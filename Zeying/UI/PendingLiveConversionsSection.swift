import Photos
import SwiftUI

struct PendingLiveConversionsSection: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let albumAssignments: PendingAlbumAssignmentStore

    @State private var selected: LivePhotoConversion?
    private let conversions = LivePhotoConversionManager.shared
    private var visibleConversions: [LivePhotoConversion] {
        conversions.visiblePendingConversions(reviews: reviews)
    }

    var body: some View {
        if let journalError = conversions.journalError {
            Section {
                Label(journalError, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 4)
            } header: {
                Text(String(localized: "静态转换记录需要检查"))
                    .zeyingAlignedGroupedSectionHeader()
                    .textCase(nil)
            }
        }

        if !visibleConversions.isEmpty {
            Section {
                ForEach(visibleConversions) { record in
                    Button {
                        selected = record
                    } label: {
                        HStack(spacing: 12) {
                            if let asset = previewAsset(for: record) {
                                AssetImageView(
                                    asset: asset,
                                    library: library,
                                    contentMode: .fill,
                                    allowNetwork: false
                                )
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                Image(systemName: "livephoto.slash")
                                    .font(.title3)
                                    .frame(width: 60, height: 60)
                                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.creationDate.zeyingShortDate)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(statusText(for: record))
                                    .font(.caption)
                                    .foregroundStyle(statusColor(for: record))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "继续实况照片转静态：\(record.creationDate.zeyingShortDate)"))
                }
            } header: {
                Label(String(localized: "待完成静态转换"), systemImage: "livephoto.slash")
                    .zeyingAlignedGroupedSectionHeader()
                    .textCase(nil)
            }
            .sheet(item: $selected) { record in
                LivePhotoConversionSheet(
                    sourceIdentifier: record.sourceIdentifier,
                    library: library,
                    reviews: reviews,
                    albumAssignments: albumAssignments
                )
            }
        }
    }

    private func previewAsset(for record: LivePhotoConversion) -> PHAsset? {
        if let stillIdentifier = record.stillIdentifier,
           let still = library.asset(with: stillIdentifier) {
            return still
        }
        return library.asset(with: record.sourceIdentifier)
    }

    private func statusText(for record: LivePhotoConversion) -> String {
        if record.phase == .preparing {
            return String(localized: "正在准备静态照片")
        }
        if record.phase == .originalDeleted {
            return record.verification == .verified
                ? String(localized: "已核对，等待完成本地记录")
                : String(localized: "本地记录待核对")
        }
        switch record.verification {
        case .verified:
            return String(localized: "静态照片已就绪，可将原件加入待删除")
        case .pending:
            return String(localized: "静态副本等待核对")
        case .failed:
            return String(localized: "静态副本核对失败，请重试")
        }
    }

    private func statusColor(for record: LivePhotoConversion) -> Color {
        switch record.verification {
        case .verified:
            return .green
        case .failed:
            return .orange
        case .pending:
            return .secondary
        }
    }
}
