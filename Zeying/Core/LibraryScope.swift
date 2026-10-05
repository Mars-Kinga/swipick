import Foundation

enum MediaCategory: String, CaseIterable, Identifiable, Codable {
    case photo
    case video
    case screenshot
    case livePhoto
    case screenRecording
    case selfie

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: String(localized: "照片")
        case .video: String(localized: "视频")
        case .screenshot: String(localized: "屏幕截图")
        case .livePhoto: String(localized: "实况照片")
        case .screenRecording: String(localized: "屏幕录制")
        case .selfie: String(localized: "自拍")
        }
    }

    var symbol: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .screenshot: "rectangle.dashed.badge.record"
        case .livePhoto: "livephoto"
        case .screenRecording: "record.circle"
        case .selfie: "person.crop.square"
        }
    }
}

enum LibraryScope: Hashable, Codable {
    case all
    case random
    case month(Date)
    case year(Date)
    case album(String)
    case category(MediaCategory)
    case later
}

struct LibraryAlbum: Identifiable {
    let id: String
    let title: String
    let count: Int
    let coverAssetIdentifier: String?
    let smartSubtypeRawValue: Int?
}
