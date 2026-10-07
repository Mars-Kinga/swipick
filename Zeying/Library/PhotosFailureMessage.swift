import Foundation
import Photos

/// App-owned messages follow the app language even when iOS reports a failure
/// in the device's language. Keep the original error at the service boundary
/// so callers can still distinguish a cancelled system confirmation.
enum PhotosFailureMessage {
    static func message(for error: Error) -> String {
        if error is PhotoLibraryServiceError || error is PhotoAlbumServiceError ||
            error is LivePhotoConversionError {
            return error.localizedDescription
        }
        if let error = error as? PHPhotosError {
            switch error.code {
            case .userCancelled:
                return String(localized: "已取消操作，本地待办仍保留。")
            case .networkAccessRequired, .networkError:
                return String(localized: "暂时无法加载云端内容，请检查网络后重试。本地预览仍可用于整理。")
            case .notEnoughSpace:
                return String(localized: "设备空间不足，未能完成照片操作。")
            case .accessRestricted:
                return String(localized: "系统限制了照片图库访问。")
            case .accessUserDenied:
                return String(localized: "没有照片图库访问权限。")
            case .identifierNotFound:
                return String(localized: "项目暂时无法访问，请检查照片权限或稍后刷新。")
            case .operationInterrupted:
                return String(localized: "照片操作已中断，请稍后重试。")
            default:
                break
            }
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain, cocoa.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return String(localized: "设备空间不足，未能完成照片操作。")
        }
        return String(localized: "照片操作未完成。请稍后重试。")
    }
}
