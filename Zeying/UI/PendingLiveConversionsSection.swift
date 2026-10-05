import Photos
import SwiftUI

struct PendingLiveConversionsSection: View {
    let library: PhotoLibraryService
    let reviews: ReviewStore
    let albumAssignments: PendingAlbumAssignmentStore

    @State private var selected: LivePhotoConversion?
    private let conversions = LivePhotoConversionManager.shared

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

        if !conversions.pendingConversions.isEmpty {
            Section {
                ForEach(conversions.pendingConversions) { record in
                    Button {
                        selected = record
                    } label: {
                        HStack(spacing: 12) {
                            if let asset = previewAsset(for: record) {
                                AssetImageView(asset: asset, library: library, contentMode: .fill)
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
                                Text(record.phase == .preparing ? String(localized: "正在准备静态照片") :
                                     record.phase == .originalDeleted ? String(localized: "完成本地记录") :
                                     String(localized: "静态副本已创建，可确认删除原件"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
            } footer: {
                Text(String(localized: "静态照片核对通过后，iOS 会确认是否删除原实况照片。"))
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
}
