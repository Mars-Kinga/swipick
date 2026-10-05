import Photos
import SwiftUI

struct AlbumPickerSheet: View {
    let albumService: PhotoAlbumService
    let onSelect: (PhotoAlbumSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newAlbumTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(localized: "选择后会视为保留，照片会先放入择影清单，确认后才写入系统照片。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section(String(localized: "我的相簿")) {
                    if albumService.albums.isEmpty {
                        Text(String(localized: "还没有可用的个人相簿"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(albumService.albums) { album in
                            Button {
                                choose(PhotoAlbumSelection(identifier: album.id, title: album.title))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "rectangle.stack")
                                        .font(.headline)
                                        .frame(width: 34, height: 34)
                                        .zeyingGlass(in: Circle())

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(album.title)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(album.count.map { String(localized: "\($0) 项") } ?? String(localized: "数量暂不可用"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "加入相簿 \(album.title)"))
                        }
                    }
                }

                Section(String(localized: "新建相簿")) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .foregroundStyle(.secondary)
                        TextField(String(localized: "例如：旅行、家人"), text: $newAlbumTitle)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.done)
                    }

                    Button {
                        chooseNewAlbum()
                    } label: {
                        Label(String(localized: "新建并加入清单"), systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(ZeyingGlassButtonStyle())
                    .disabled(trimmedNewAlbumTitle.isEmpty)
                    .listRowBackground(Color.clear)
                }

                if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                    Section {
                        Label(String(localized: "当前是有限照片权限。最终确认时只能整理已授权的照片。"), systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(String(localized: "加入相簿"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
            .task {
                albumService.refresh()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var trimmedNewAlbumTitle: String {
        newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chooseNewAlbum() {
        let title = trimmedNewAlbumTitle
        guard !title.isEmpty else { return }
        choose(PhotoAlbumSelection(identifier: nil, title: title))
    }

    private func choose(_ selection: PhotoAlbumSelection) {
        onSelect(selection)
        dismiss()
    }
}
