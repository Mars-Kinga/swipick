import CryptoKit
import Foundation

enum SuggestionKind: String, Codable, CaseIterable, Sendable {
    case duplicates, similar, screenshots

    var title: String {
        switch self {
        case .duplicates: String(localized: "重复副本")
        case .similar: String(localized: "相似照片")
        case .screenshots: String(localized: "临时截图")
        }
    }

    var symbol: String {
        switch self {
        case .duplicates: "doc.on.doc"
        case .similar: "photo.on.rectangle.angled"
        case .screenshots: "rectangle.dashed"
        }
    }
}

enum SuggestionReason: String, Codable, Sendable {
    case identicalResources, possibleVersions, nearbyShots, pastEvent, olderScreenshots
    case olderOrders, olderPickupCodes, olderVerificationCodes, olderDeliveries, expiredOffers

    var title: String {
        switch self {
        case .identicalResources: String(localized: "已确认资源内容相同")
        case .possibleVersions: String(localized: "画面相近的不同版本，可以同时保留")
        case .nearbyShots: String(localized: "短时间内拍摄的同一场景")
        case .pastEvent: String(localized: "识别到的活动日期已经过去，请核对内容")
        case .olderScreenshots: String(localized: "超过 90 天的截图，可集中检查是否仍需保留")
        case .olderOrders: String(localized: "超过 90 天的已完成订单，可逐张核对是否仍需保留")
        case .olderPickupCodes: String(localized: "超过 90 天的取件信息，可逐张核对是否仍需保留")
        case .olderVerificationCodes: String(localized: "超过 90 天的验证码，可逐张核对是否仍需保留")
        case .olderDeliveries: String(localized: "超过 90 天的已送达物流信息，可逐张核对是否仍需保留")
        case .expiredOffers: String(localized: "超过 90 天的已过期或已使用优惠券，可逐张核对是否仍需保留")
        }
    }
}

enum TemporaryScreenshotKind: String, Codable, CaseIterable, Sendable {
    case completedOrders, pickupCodes, verificationCodes, pastEvents, completedDeliveries, expiredOffers

    var reason: SuggestionReason {
        switch self {
        case .completedOrders: .olderOrders
        case .pickupCodes: .olderPickupCodes
        case .verificationCodes: .olderVerificationCodes
        case .pastEvents: .pastEvent
        case .completedDeliveries: .olderDeliveries
        case .expiredOffers: .expiredOffers
        }
    }
}

/// Age alone says nothing about whether a screenshot is disposable. Require
/// specific temporary content; even a match remains a manual review suggestion.
enum TemporaryScreenshotClassifier {
    // Cached classifications do not retain OCR text. Bump this when changing
    // the rules so older screenshots are checked again with the new evidence.
    static let version = 2

    static func classify(_ text: String) -> TemporaryScreenshotKind? {
        func contains(_ terms: [String]) -> Bool {
            terms.contains { text.localizedCaseInsensitiveContains($0) }
        }
        if contains(["取件码", "取货码", "提货码", "取件编号", "提货凭证", "pickup code", "collection code"]) { return .pickupCodes }
        if contains(["验证码", "一次性密码", "verification code", "one-time password", "one time code", "one-time passcode", "security code"]) {
            return .verificationCodes
        }
        if contains(["订单", "order"]) && contains(["交易成功", "交易完成", "支付成功", "支付完成", "已完成", "已收货", "已签收", "订单完成", "delivered", "completed", "payment successful"]) {
            return .completedOrders
        }
        if contains(["快递", "物流", "包裹", "配送", "package", "shipment", "delivery", "tracking"]) &&
            contains(["已签收", "已送达", "配送完成", "delivered", "delivery completed"]) {
            return .completedDeliveries
        }
        if contains(["优惠券", "代金券", "折扣券", "coupon", "voucher"]) &&
            contains(["已过期", "已使用", "已失效", "expired", "redeemed"]) {
            return .expiredOffers
        }
        if !ScreenshotEventDate.eventDates(in: text).isEmpty { return .pastEvents }
        return nil
    }
}

struct SuggestionAsset: Codable, Hashable, Sendable {
    let id: String
    let modifiedAt: Date?
    let createdAt: Date?
    let width: Int
    let height: Int
    let isScreenshot: Bool
    let isLivePhoto: Bool
    let burstID: String?
    var isProtected: Bool
    var isEligible: Bool

    var pixelCount: Int64 { Int64(width) * Int64(height) }
    var aspectRatio: Double { Double(width) / Double(max(height, 1)) }
}

struct SuggestionAnalysis: Codable, Sendable {
    let asset: SuggestionAsset
    let differenceHash: UInt64
    let featurePrint: Data
    let hasPastEvent: Bool
    var eventDates: [Date]? = nil
    var temporaryScreenshotKind: TemporaryScreenshotKind? = nil
    var screenshotContentChecked: Bool? = nil
    var screenshotClassifierVersion: Int? = nil
    var previewUnavailableAt: Date? = nil
    var resourceDigest: String?
    var resourceBytes: Int64?
    var checkedResources = false
    /// Vision's -1...1 overall aesthetics score. Missing values from older
    /// caches are filled only for assets that enter a comparison group.
    var aestheticScore: Float? = nil
    var aestheticChecked: Bool? = nil
    var portraitEvidence: SuggestionPortraitEvidence? = nil
    var portraitChecked: Bool? = nil
    var portraitClassifierVersion: Int? = nil

    func matches(_ current: SuggestionAsset) -> Bool {
        asset.id == current.id && asset.modifiedAt == current.modifiedAt &&
        asset.width == current.width && asset.height == current.height &&
        asset.isLivePhoto == current.isLivePhoto && asset.isScreenshot == current.isScreenshot && asset.createdAt == current.createdAt
    }

    var hasCurrentScreenshotClassification: Bool {
        !asset.isScreenshot || (eventDates != nil && screenshotContentChecked == true &&
                                screenshotClassifierVersion == TemporaryScreenshotClassifier.version)
    }

    func hasPastEvent(at now: Date) -> Bool {
        guard let eventDates else { return hasPastEvent }
        return eventDates.contains {
            Calendar.current.date(byAdding: .day, value: 1, to: $0).map { $0 < now } ?? false
        }
    }
}

enum SuggestionRecommendationBasis: String, Codable, Hashable, Sendable {
    case protected, visionAesthetics, resolution, identicalResources
}

/// Evidence from a small local preview, checked only for an opened comparison.
/// A missing observation is never treated as proof that a face is absent.
struct SuggestionPortraitEvidence: Codable, Hashable, Sendable {
    let faceCount: Int
    let averageCaptureQuality: Float?
    let largestFaceArea: Float
    var dominantFaceQuality: Float? = nil
    var dominantCenterX: Float? = nil
    var dominantCenterY: Float? = nil
    var secondLargestFaceArea: Float? = nil

    static let classifierVersion = 3

    var hasUsefulFace: Bool { faceCount > 0 && largestFaceArea >= 0.012 }

    var hasClearSubject: Bool {
        guard largestFaceArea >= 0.025, let dominantCenterX, let dominantCenterY,
              let secondLargestFaceArea else { return false }
        return abs(dominantCenterX - 0.5) <= 0.4 &&
            abs(dominantCenterY - 0.5) <= 0.4 &&
            secondLargestFaceArea <= largestFaceArea * 0.8
    }
}

struct CleanupSuggestion: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: SuggestionKind
    let reason: SuggestionReason
    let assetIDs: [String]
    var recommendedKeepID: String?
    let protectedIDs: Set<String>
    let knownBytes: Int64?
    let newestDate: Date?
    var recommendationBasis: SuggestionRecommendationBasis? = nil
    var suggestedKeeperIDs: Set<String>? = nil
    var aestheticLead: Float? = nil
    var aestheticScores: [String: Float] = [:]
    var aestheticEvaluationComplete = false
    var portraitEvidence: [String: SuggestionPortraitEvidence]? = nil
    var portraitEvaluationComplete: Bool? = nil
    var portraitClassifierVersion: Int? = nil

    var hasPortraitRecommendation: Bool {
        guard kind == .similar, portraitEvaluationComplete == true,
              portraitClassifierVersion == SuggestionPortraitEvidence.classifierVersion,
              let portraitEvidence, !portraitEvidence.isEmpty else { return false }
        return assetIDs.contains { portraitReason(for: $0) != nil }
    }

    var visibleSuggestedKeeperIDs: Set<String> {
        let valid = (suggestedKeeperIDs ?? []).intersection(assetIDs)
        if !valid.isEmpty { return valid }
        guard let recommendedKeepID, assetIDs.contains(recommendedKeepID) else { return [] }
        return [recommendedKeepID]
    }

    var priority: Int {
        switch reason {
        case .identicalResources: 5
        case .possibleVersions: 3
        case .nearbyShots: 3
        case .pastEvent: 2
        case .olderScreenshots, .olderOrders, .olderPickupCodes, .olderVerificationCodes,
             .olderDeliveries, .expiredOffers: 1
        }
    }

    func portraitReason(for assetID: String) -> String? {
        guard kind == .similar,
              portraitClassifierVersion == SuggestionPortraitEvidence.classifierVersion,
              let evidence = portraitEvidence,
              let candidate = evidence[assetID], candidate.hasUsefulFace else { return nil }
        let peers = assetIDs.filter { $0 != assetID }.compactMap { evidence[$0] }
            .filter(\.hasUsefulFace)
        guard !peers.isEmpty else { return nil }
        let quality = candidate.averageCaptureQuality ?? candidate.dominantFaceQuality
        let highestOtherQuality = peers.compactMap { $0.averageCaptureQuality ?? $0.dominantFaceQuality }.max()
        let qualityNotWorse: Bool
        if let quality, let highestOtherQuality {
            qualityNotWorse = quality >= highestOtherQuality - 0.05
        } else {
            qualityNotWorse = true
        }
        if let quality, let highestOtherQuality, quality - highestOtherQuality >= 0.10 {
            return String(localized: "人物面部成像质量更好")
        }
        if let quality, let highestOtherQuality, quality - highestOtherQuality >= 0.015 {
            return String(localized: "面部成像评分略高")
        }
        if candidate.hasClearSubject,
           let largestOther = peers.filter(\.hasClearSubject).map(\.largestFaceArea).max(),
           candidate.largestFaceArea - largestOther >= 0.018,
           candidate.largestFaceArea >= largestOther * 1.35,
           qualityNotWorse {
            return String(localized: "主体面部在画面中更大")
        }
        let comparableIDs = assetIDs.filter { $0 != assetID && evidence[$0]?.hasUsefulFace == true }
        let highestOtherScore = comparableIDs.compactMap { aestheticScores[$0] }.max()
        if let score = aestheticScores[assetID], let highestOtherScore,
           score - highestOtherScore >= 0.12 {
            return String(localized: "人像画面整体观感更好")
        }
        if let score = aestheticScores[assetID], let highestOtherScore,
           score - highestOtherScore >= 0.02 {
            return String(localized: "人像画面评分略高")
        }
        return nil
    }

    static func signature(kind: SuggestionKind, assets: [SuggestionAsset]) -> String {
        let input = assets.sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.modifiedAt?.timeIntervalSince1970 ?? 0):\($0.width)x\($0.height)"
        }.joined(separator: "\n")
        return kind.rawValue + ":" + SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Groups around a seed and checks every member. This avoids merging a chain
/// of individually similar pairs into a group whose endpoints are unrelated.
enum SuggestionGrouping {
    // A changed pose can move Vision's feature print farther apart even when
    // the backdrop and capture window are the same. Use the looser threshold
    // only after a close pair anchors the group; the all-members check then
    // prevents chain merging across unrelated endpoints.
    private static let nearbyPairDistance: Float = 0.22
    private static let nearbySceneDistance: Float = 0.35
    // A short run of selfies can change poses enough to exceed the general
    // scene threshold. Only use these bounds within the same brief capture
    // window, and still compare a candidate with every member of the group.
    private static let quickSequenceWindow: TimeInterval = 90
    private static let quickSequencePairDistance: Float = 0.26
    private static let quickSequenceSceneDistance: Float = 0.43
    private static let quickSequenceNeighborDistance: Float = 0.38
    private static let quickSequencePairHashBits = 18

    static func build(
        assets: [SuggestionAsset],
        analyses: [String: SuggestionAnalysis],
        now: Date = .now,
        isCancelled: () -> Bool = { false },
        distance: (String, String) -> Float?
    ) -> [CleanupSuggestion] {
        let ordered = assets.sorted {
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            return $0.id < $1.id
        }
        guard !isCancelled() else { return [] }
        var used = Set<String>()
        var result: [CleanupSuggestion] = []

        func append(_ members: [SuggestionAsset], kind: SuggestionKind, reason: SuggestionReason) {
            guard members.contains(where: \.isEligible), members.count >= (kind == .screenshots ? 1 : 2) else { return }
            let recommendation = SuggestionKeeperRanking.choose(members: members, analyses: analyses, kind: kind)
            let bytes = members.compactMap { analyses[$0.id]?.resourceBytes }
            var suggestion = CleanupSuggestion(
                id: CleanupSuggestion.signature(kind: kind, assets: members), kind: kind, reason: reason,
                assetIDs: members.map(\.id), recommendedKeepID: recommendation.id,
                protectedIDs: Set(members.filter(\.isProtected).map(\.id)),
                knownBytes: bytes.count == members.count ? bytes.reduce(0, +) : nil,
                newestDate: members.compactMap(\.createdAt).max()
            )
            suggestion.recommendationBasis = recommendation.basis
            suggestion.suggestedKeeperIDs = SuggestionKeeperRanking.chooseHighlights(
                members: members, analyses: analyses, reason: reason,
                primaryID: recommendation.id, distance: distance)
            suggestion.aestheticLead = recommendation.lead
            suggestion.aestheticScores = Dictionary(uniqueKeysWithValues: members.compactMap { member in
                analyses[member.id]?.aestheticScore.map { (member.id, $0) }
            })
            suggestion.aestheticEvaluationComplete = kind == .similar &&
                members.allSatisfy { analyses[$0.id]?.aestheticChecked == true }
            if kind == .similar && members.allSatisfy({ analyses[$0.id]?.portraitClassifierVersion == SuggestionPortraitEvidence.classifierVersion }) {
                suggestion.portraitEvidence = Dictionary(uniqueKeysWithValues: members.compactMap { member in
                    analyses[member.id]?.portraitEvidence.map { (member.id, $0) }
                })
                suggestion.portraitEvaluationComplete = true
                suggestion.portraitClassifierVersion = SuggestionPortraitEvidence.classifierVersion
            }
            result.append(suggestion)
            used.formUnion(members.map(\.id))
        }

        let exact = Dictionary(grouping: ordered.filter { analyses[$0.id]?.resourceDigest != nil }) {
            analyses[$0.id]!.resourceDigest!
        }
        for key in exact.keys.sorted() { append(exact[key] ?? [], kind: .duplicates, reason: .identicalResources) }

        // Four hash bands give bounded global candidate lookup even when
        // copies have different capture dates. Hashes only nominate pairs;
        // Vision must agree before a suggestion is created.
        var bands: [UInt64: [Int]] = [:]
        for (index, asset) in ordered.enumerated() where !asset.isScreenshot {
            guard !isCancelled() else { return [] }
            guard let analysis = analyses[asset.id], analysis.previewUnavailableAt == nil else { continue }
            for band in 0..<4 {
                let key = (UInt64(band) << 16) | ((analysis.differenceHash >> (band * 16)) & 0xffff)
                bands[key, default: []].append(index)
            }
        }
        for (seedIndex, seed) in ordered.enumerated() where !used.contains(seed.id) && !seed.isScreenshot {
            guard !isCancelled() else { return [] }
            guard let seedAnalysis = analyses[seed.id], seedAnalysis.previewUnavailableAt == nil else { continue }
            var candidates: [String: SuggestionAsset] = [:]
            for band in 0..<4 {
                let key = (UInt64(band) << 16) | ((seedAnalysis.differenceHash >> (band * 16)) & 0xffff)
                let bucket = bands[key] ?? []
                // Anchor the bounded window at this seed, so earlier hash
                // collisions cannot hide similar pairs later in the library.
                var lower = 0, upper = bucket.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if bucket[middle] < seedIndex { lower = middle + 1 } else { upper = middle }
                }
                for index in bucket.dropFirst(lower).prefix(256) {
                    let candidate = ordered[index]
                    candidates[candidate.id] = candidate
                }
            }
            var members = [seed]
            var memberIDs: Set<String> = [seed.id]
            for candidate in candidates.values.sorted(by: { $0.id < $1.id }) where candidate.id != seed.id && !used.contains(candidate.id) {
                guard candidate.isLivePhoto == seed.isLivePhoto,
                      candidate.isScreenshot == seed.isScreenshot,
                      abs(candidate.aspectRatio - seed.aspectRatio) < 0.015,
                      let candidateAnalysis = analyses[candidate.id],
                      (seedAnalysis.differenceHash ^ candidateAnalysis.differenceHash).nonzeroBitCount <= 3,
                      members.allSatisfy({ (distance($0.id, candidate.id) ?? 1) < 0.08 }) else { continue }
                // Two fully checked, different resources can still look alike,
                // but remain probable copies rather than confirmed duplicates.
                members.append(candidate)
                memberIDs.insert(candidate.id)
            }
            // Expand the strong visual matches with shots from the same
            // capture window before reserving any members. Otherwise three
            // near-identical pairs become three separate two-photo groups.
            var addedNearbyShot = false
            if let seedDate = seed.createdAt {
                for pass in 0..<2 {
                    guard pass == 0 || members.count >= 2 else { break }
                    // The close partner may appear after other poses in time.
                    // Revisit earlier candidates once that partner anchors a
                    // reliable group, using the scene threshold for expansion.
                    for candidate in ordered.dropFirst(seedIndex + 1).prefix(128) {
                        guard let date = candidate.createdAt else { continue }
                        let sameBurst = seed.burstID != nil && seed.burstID == candidate.burstID
                        if date.timeIntervalSince(seedDate) > 5 * 60 && !sameBurst { break }
                        let quickSequence = date.timeIntervalSince(seedDate) <= quickSequenceWindow &&
                            abs(candidate.aspectRatio - seed.aspectRatio) < 0.08
                        let threshold = members.count >= 2
                            ? (quickSequence ? quickSequenceSceneDistance : nearbySceneDistance)
                            : (quickSequence ? quickSequencePairDistance : nearbyPairDistance)
                        guard !used.contains(candidate.id), !memberIDs.contains(candidate.id),
                              !candidate.isScreenshot, candidate.isLivePhoto == seed.isLivePhoto,
                              abs(candidate.aspectRatio - seed.aspectRatio) < 0.15 else { continue }
                        var closestDistance: Float = 1
                        let matchesEveryMember = members.allSatisfy { member in
                            let value = distance(member.id, candidate.id) ?? 1
                            closestDistance = min(closestDistance, value)
                            return value < threshold
                        }
                        let closeHash = analyses[candidate.id].map { candidateAnalysis in
                            (seedAnalysis.differenceHash ^ candidateAnalysis.differenceHash).nonzeroBitCount <= quickSequencePairHashBits
                        } ?? false
                        guard matchesEveryMember,
                              !quickSequence || members.count >= 2 ||
                              closestDistance < nearbyPairDistance || closeHash,
                              !quickSequence || members.count < 2 ||
                              closestDistance < quickSequenceNeighborDistance else { continue }
                        members.append(candidate)
                        memberIDs.insert(candidate.id)
                        addedNearbyShot = true
                    }
                }
            }
            append(members, kind: .similar, reason: addedNearbyShot ? .nearbyShots : .possibleVersions)
        }

        let cutoff = now.addingTimeInterval(-90 * 86_400)
        for category in TemporaryScreenshotKind.allCases {
            let screenshots = ordered.filter {
                guard $0.isEligible, $0.isScreenshot, !used.contains($0.id),
                      ($0.createdAt ?? .distantFuture) < cutoff,
                      let analysis = analyses[$0.id], analysis.screenshotContentChecked == true,
                      analysis.temporaryScreenshotKind == category else { return false }
                return category != .pastEvents || analysis.hasPastEvent(at: now)
            }
            append(screenshots, kind: .screenshots, reason: category.reason)
        }
        return result.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.assetIDs.count != $1.assetIDs.count { return $0.assetIDs.count > $1.assetIDs.count }
            if $0.knownBytes != $1.knownBytes { return ($0.knownBytes ?? 0) > ($1.knownBytes ?? 0) }
            if $0.newestDate != $1.newestDate { return ($0.newestDate ?? .distantPast) < ($1.newestDate ?? .distantPast) }
            return $0.id < $1.id
        }
    }
}

enum SuggestionKeeperRanking {
    static func choose(
        members: [SuggestionAsset], analyses: [String: SuggestionAnalysis], kind: SuggestionKind
    ) -> (id: String?, basis: SuggestionRecommendationBasis?, lead: Float?) {
        guard kind != .screenshots else { return (nil, nil, nil) }
        if let protected = members.filter(\.isProtected).sorted(by: { $0.id < $1.id }).first {
            return (protected.id, .protected, nil)
        }
        if kind == .duplicates {
            return (members.map(\.id).sorted().first, .identicalResources, nil)
        }
        let ranked = members.compactMap { member -> (asset: SuggestionAsset, score: Float)? in
            guard let score = analyses[member.id]?.aestheticScore, score.isFinite else { return nil }
            return (member, score)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.asset.pixelCount != $1.asset.pixelCount { return $0.asset.pixelCount > $1.asset.pixelCount }
            return $0.asset.id < $1.asset.id
        }
        guard ranked.count == members.count, let best = ranked.first, ranked.count >= 2 else {
            return (nil, nil, nil)
        }
        let lead = best.score - ranked[1].score
        if lead > 0.005 { return (best.asset.id, .visionAesthetics, lead) }
        let byResolution = members.sorted {
            if $0.pixelCount != $1.pixelCount { return $0.pixelCount > $1.pixelCount }
            return $0.id < $1.id
        }
        if byResolution[0].pixelCount > byResolution[1].pixelCount {
            return (byResolution[0].id, .resolution, nil)
        }
        return (nil, nil, nil)
    }

    static func chooseHighlights(
        members: [SuggestionAsset], analyses: [String: SuggestionAnalysis],
        reason: SuggestionReason, primaryID: String?,
        distance: (String, String) -> Float?
    ) -> Set<String> {
        guard let primaryID, members.contains(where: { $0.id == primaryID }) else { return [] }
        var selected = [primaryID]
        guard case .nearbyShots = reason, members.count >= 4,
              !members.contains(where: { $0.id == primaryID && $0.isProtected }),
              let topScore = analyses[primaryID]?.aestheticScore, topScore.isFinite else {
            return Set(selected)
        }
        let limit = min(4, max(2, members.count / 3))
        let candidates = members.compactMap { member -> (id: String, score: Float)? in
            guard member.id != primaryID, !member.isProtected,
                  let score = analyses[member.id]?.aestheticScore, score.isFinite,
                  score >= topScore - 0.08 else { return nil }
            return (member.id, score)
        }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        for candidate in candidates {
            guard selected.allSatisfy({ (distance($0, candidate.id) ?? 0) >= 0.16 }) else { continue }
            selected.append(candidate.id)
            if selected.count >= limit { break }
        }
        return Set(selected)
    }
}

enum SuggestionReviewQueue {
    static func initialIndex(of group: CleanupSuggestion?, in groups: [CleanupSuggestion]) -> Int {
        guard let group else { return 0 }
        return groups.firstIndex(where: { $0.id == group.id }) ?? 0
    }

    static func orderedAssetIDs(in group: CleanupSuggestion) -> [String] {
        let portraitSuggestedIDs = Set(group.assetIDs.filter { group.portraitReason(for: $0) != nil })
        return group.assetIDs.enumerated().sorted { left, right in
            let leftRecommended = left.element == group.recommendedKeepID
            let rightRecommended = right.element == group.recommendedKeepID
            if leftRecommended != rightRecommended { return leftRecommended }

            let leftHasPortraitSuggestion = portraitSuggestedIDs.contains(left.element)
            let rightHasPortraitSuggestion = portraitSuggestedIDs.contains(right.element)
            if leftHasPortraitSuggestion != rightHasPortraitSuggestion { return leftHasPortraitSuggestion }

            let leftScore = group.aestheticScores[left.element].flatMap { $0.isFinite ? $0 : nil }
            let rightScore = group.aestheticScores[right.element].flatMap { $0.isFinite ? $0 : nil }
            switch (leftScore, rightScore) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }

    static func keepersToSelect(in group: CleanupSuggestion, visibleAssetIDs: [String]) -> Set<String> {
        let suggested = group.visibleSuggestedKeeperIDs.intersection(visibleAssetIDs)
        return suggested.isEmpty ? Set(visibleAssetIDs.prefix(1)) : suggested
    }
}

enum SuggestionCheckBudget {
    static func shouldPause(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState,
        background: Bool = true,
        isCharging: Bool = false
    ) -> Bool {
        thermalState == .critical || thermalState == .serious ||
            (background && lowPowerMode && !isCharging)
    }
}

enum SuggestionScanPace {
    static func analysisLimit(isCharging: Bool) -> Int { isCharging ? .max : 48 }
    static func resourceLimit(isCharging: Bool) -> Int { isCharging ? 16 : 4 }
    static let foregroundScoreLimit = 24
    static let foregroundResourceLimit = 4
    static func itemDelay(isCharging: Bool) -> Duration {
        isCharging ? .zero : .milliseconds(300)
    }
    static func foregroundItemDelay(
        isCharging: Bool,
        thermalState: ProcessInfo.ThermalState = .nominal,
        lowPowerMode: Bool = false
    ) -> Duration {
        if thermalState != .nominal || lowPowerMode { return .milliseconds(600) }
        return isCharging ? .milliseconds(120) : .milliseconds(300)
    }

    static func effectiveDelay(background: Bool, isCharging: Bool) -> Duration {
        let process = ProcessInfo.processInfo
        if process.thermalState != .nominal || process.isLowPowerModeEnabled { return .milliseconds(600) }
        return background ? itemDelay(isCharging: isCharging) : foregroundItemDelay(isCharging: isCharging)
    }
}
