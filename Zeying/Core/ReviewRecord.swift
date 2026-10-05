import Foundation
import SwiftData

enum ReviewDecision: String, CaseIterable, Codable {
    case keep
    case delete
    case later

    var title: String {
        switch self {
        case .keep: String(localized: "已保留")
        case .delete: String(localized: "待删除")
        case .later: String(localized: "待决定")
        }
    }
}

@Model
final class ReviewRecord {
    @Attribute(.unique) var assetIdentifier: String
    var decisionRawValue: String
    var pendingFavorite: Bool
    var updatedAt: Date

    init(assetIdentifier: String, decision: ReviewDecision, pendingFavorite: Bool = false) {
        self.assetIdentifier = assetIdentifier
        self.decisionRawValue = decision.rawValue
        self.pendingFavorite = pendingFavorite
        self.updatedAt = .now
    }

    var decision: ReviewDecision {
        get { ReviewDecision(rawValue: decisionRawValue) ?? .later }
        set { decisionRawValue = newValue.rawValue }
    }
}
