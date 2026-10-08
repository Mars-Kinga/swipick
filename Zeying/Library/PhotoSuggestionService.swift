import CryptoKit
import Foundation
import Observation
@preconcurrency import Photos
import UIKit
import Vision

@MainActor
@Observable
final class PhotoSuggestionService {
    private(set) var groups: [CleanupSuggestion] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var checkedCount = 0
    private(set) var totalCount = 0
    private(set) var unavailableCount = 0
    private(set) var isVerifyingCopies = false
    private(set) var lastScanDate: Date?
    private(set) var lastBackgroundRunDate: Date?
    private(set) var errorMessage: String?
    private(set) var backgroundScheduleError: String?
    private(set) var isManuallyPaused = false
    private(set) var isEnergyPaused = false
    private(set) var skippedIDs: Set<String>
    private(set) var resumeGroupIDs: [String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let analyzer = PhotoSuggestionAnalyzer()
    @ObservationIgnored private let snapshotWriter: SuggestionGroupSnapshotWriter
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var priorityAttemptedGroupIDs = Set<String>()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var libraryRevision: Int?
    /// Album choices are local protection tasks. Keep them out of generated
    /// cleanup suggestions even though the Photos asset itself is still
    /// accessible and has no ReviewStore decision yet.
    @ObservationIgnored private var albumAssignments: PendingAlbumAssignmentStore?
    private static let skippedKey = "com.mars.zeying.skippedSuggestions.v1"
    private static let resumeKey = "com.mars.zeying.suggestionSession.v1"
    private static let manualPauseKey = "com.mars.zeying.suggestionManualPause.v1"
    private static let backgroundEnabledKey = "com.mars.zeying.suggestionBackgroundCheck.v1"
    private static let lastBackgroundRunKey = "com.mars.zeying.lastBackgroundSuggestionRun.v1"

    var isCharging: Bool {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        return device.batteryState == .charging || device.batteryState == .full
    }

    init(defaults: UserDefaults = .standard, snapshotURL: URL = SuggestionGroupSnapshot.defaultURL) {
        self.defaults = defaults
        snapshotWriter = SuggestionGroupSnapshotWriter(url: snapshotURL)
        if let snapshot = SuggestionGroupSnapshot.load(from: snapshotURL) {
            groups = snapshot.groups
            // Keep showing saved suggestions while a changed grouping rule
            // rebuilds them from the local analysis cache.
            let groupingIsCurrent = snapshot.groupingVersion == SuggestionGroupSnapshot.currentGroupingVersion
            hasScanned = groupingIsCurrent && snapshot.hasScanned
            lastScanDate = groupingIsCurrent && snapshot.hasScanned ? snapshot.lastScanDate : nil
            checkedCount = snapshot.progress?.checked ?? 0
            totalCount = snapshot.progress?.total ?? 0
            unavailableCount = snapshot.progress?.unavailable ?? 0
        }
        lastBackgroundRunDate = defaults.object(forKey: Self.lastBackgroundRunKey) as? Date
        if defaults.object(forKey: Self.backgroundEnabledKey) == nil {
            defaults.set(true, forKey: Self.backgroundEnabledKey)
        }
        skippedIDs = Set(defaults.stringArray(forKey: Self.skippedKey) ?? [])
        resumeGroupIDs = defaults.stringArray(forKey: Self.resumeKey) ?? []
        isManuallyPaused = defaults.bool(forKey: Self.manualPauseKey)
    }

    /// Injected after the SwiftData stores are created during app startup.
    /// Keeping this separate preserves the lightweight initializer used by
    /// tests and avoids constructing the model container twice.
    func setAlbumAssignments(_ store: PendingAlbumAssignmentStore?) {
        albumAssignments = store
    }

    func visibleAssetIDs(in group: CleanupSuggestion, library: PhotoLibraryService, reviews: ReviewStore) -> [String] {
        guard group.kind == .screenshots else { return group.assetIDs }
        return group.assetIDs.filter { isEligibleScreenshotAsset($0, library: library, reviews: reviews) }
    }

    func availableGroups(library: PhotoLibraryService, reviews: ReviewStore, includeSkipped: Bool = false) -> [CleanupSuggestion] {
        groups.filter { group in
            (includeSkipped || !skippedIDs.contains(group.id)) &&
            isCurrent(group, library: library) &&
            group.assetIDs.contains {
                group.kind == .screenshots
                    ? isEligibleScreenshotAsset($0, library: library, reviews: reviews)
                    : reviews.decision(for: $0) == nil && library.asset(with: $0)?.isFavorite == false && !reviews.isPendingFavorite($0)
            } &&
            (group.kind == .screenshots || !group.assetIDs.contains { reviews.decision(for: $0) == .delete || reviews.decision(for: $0) == .later })
        }
    }

    /// This pure predicate is shared by the row and queue paths so a pending
    /// album action cannot leave an empty screenshot group visible.
    static func isEligibleScreenshotAsset(
        isFavorite: Bool,
        hasDecision: Bool,
        isPendingFavorite: Bool,
        hasAlbumAssignment: Bool
    ) -> Bool {
        !hasDecision && !isFavorite && !isPendingFavorite && !hasAlbumAssignment
    }

    private func isEligibleScreenshotAsset(
        _ identifier: String,
        library: PhotoLibraryService,
        reviews: ReviewStore
    ) -> Bool {
        guard let asset = library.asset(with: identifier) else { return false }
        return Self.isEligibleScreenshotAsset(
            isFavorite: asset.isFavorite,
            hasDecision: reviews.decision(for: identifier) != nil,
            isPendingFavorite: reviews.isPendingFavorite(identifier),
            hasAlbumAssignment: albumAssignments?.assignment(for: identifier) != nil
        )
    }

    func isCurrent(_ group: CleanupSuggestion, library: PhotoLibraryService) -> Bool {
        let assets = group.assetIDs.compactMap { id -> SuggestionAsset? in
            guard let asset = library.asset(with: id) else { return nil }
            return SuggestionAsset(id: id, modifiedAt: asset.modificationDate, createdAt: asset.creationDate,
                                   width: asset.pixelWidth, height: asset.pixelHeight,
                                   isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                                   isLivePhoto: asset.mediaSubtypes.contains(.photoLive), burstID: asset.burstIdentifier,
                                   isProtected: false, isEligible: true)
        }
        return assets.count == group.assetIDs.count && CleanupSuggestion.signature(kind: group.kind, assets: assets) == group.id
    }

    func startIfNeeded(library: PhotoLibraryService, reviews: ReviewStore) {
        let needsDailyRefresh = lastScanDate.map { !Calendar.current.isDateInToday($0) } ?? true
        guard library.hasLoaded, SuggestionScanStartPolicy.shouldStart(
            manuallyPaused: isManuallyPaused, isScanning: isScanning,
            scannedRevision: libraryRevision, currentRevision: library.suggestionRevision,
            hasScanned: hasScanned, needsDailyRefresh: needsDailyRefresh
        ) else { return }
        if SuggestionCheckBudget.shouldPause(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                             thermalState: ProcessInfo.processInfo.thermalState,
                                             background: false, isCharging: isCharging) {
            isEnergyPaused = true
            scheduleBackgroundCheck()
            return
        }
        start(library: library, reviews: reviews)
    }

    /// Score the group the user opened before the rest of the library. A full
    /// scan may take minutes, but it must not hold this screen's recommendation.
    func prioritizeRecommendation(for group: CleanupSuggestion, library: PhotoLibraryService) async {
        guard group.kind == .similar,
              let position = groups.firstIndex(where: { $0.id == group.id }),
              groups[position].aestheticScores.count < group.assetIDs.count,
              !priorityAttemptedGroupIDs.contains(group.id) else { return }
        priorityAttemptedGroupIDs.insert(group.id)
        let members = group.assetIDs.compactMap { identifier -> SuggestionAsset? in
            guard let asset = library.asset(with: identifier) else { return nil }
            let protected = group.protectedIDs.contains(identifier)
            return SuggestionAsset(
                id: identifier, modifiedAt: asset.modificationDate, createdAt: asset.creationDate,
                width: asset.pixelWidth, height: asset.pixelHeight,
                isScreenshot: false, isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                burstID: asset.burstIdentifier, isProtected: protected, isEligible: !protected
            )
        }
        guard members.count == group.assetIDs.count else { return }
        let activeGeneration = generation
        let scored = await analyzer.scorePriority(members)
        guard !Task.isCancelled, generation == activeGeneration,
              let currentPosition = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let recommendation = SuggestionKeeperRanking.choose(members: members, analyses: scored, kind: .similar)
        var updated = groups[currentPosition]
        updated.recommendedKeepID = recommendation.id
        updated.recommendationBasis = recommendation.basis
        updated.aestheticLead = recommendation.lead
        updated.aestheticScores = Dictionary(uniqueKeysWithValues: members.compactMap { member in
            scored[member.id]?.aestheticScore.map { (member.id, $0) }
        })
        updated.aestheticEvaluationComplete = true
        groups[currentPosition] = updated
        saveGroupSnapshot()
    }

    func start(library: PhotoLibraryService, reviews: ReviewStore, background: Bool = false) {
        pause()
        priorityAttemptedGroupIDs.removeAll()
        isManuallyPaused = false
        defaults.set(false, forKey: Self.manualPauseKey)
        defaults.set(true, forKey: Self.backgroundEnabledKey)
        hasScanned = false
        isEnergyPaused = SuggestionCheckBudget.shouldPause(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                         thermalState: ProcessInfo.processInfo.thermalState,
                                                         background: background, isCharging: isCharging)
        guard !isEnergyPaused else { scheduleBackgroundCheck(); return }
        let descriptors = library.assets.filter { $0.mediaType == .image }.map { asset in
            let decision = reviews.decision(for: asset.localIdentifier)
            let protected = asset.isFavorite || reviews.isPendingFavorite(asset.localIdentifier) || decision == .keep ||
                albumAssignments?.assignment(for: asset.localIdentifier) != nil
            return SuggestionAsset(
                id: asset.localIdentifier, modifiedAt: asset.modificationDate, createdAt: asset.creationDate,
                width: asset.pixelWidth, height: asset.pixelHeight,
                isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive), burstID: asset.burstIdentifier,
                isProtected: protected, isEligible: decision == nil && !protected
            )
        }.filter { $0.isEligible || $0.isProtected }
        libraryRevision = library.suggestionRevision
        let currentGeneration = UUID()
        generation = currentGeneration
        isScanning = true
        errorMessage = nil
        totalCount = descriptors.count
        checkedCount = min(checkedCount, totalCount)
        saveGroupSnapshot()
        let charging = isCharging
        scanTask = Task(priority: background ? .background : .utility) { [weak self, analyzer] in
            let receiver = self
            await analyzer.scan(descriptors, background: background, isCharging: charging) { update in
                await receiver?.receive(update, generation: currentGeneration)
            }
        }
    }

    func pause(manually: Bool = false) {
        if manually {
            isManuallyPaused = true
            isEnergyPaused = false
            defaults.set(true, forKey: Self.manualPauseKey)
            PhotoSuggestionBackgroundTask.cancelPending()
        }
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        isVerifyingCopies = false
    }

    var backgroundCheckingEnabled: Bool { defaults.bool(forKey: Self.backgroundEnabledKey) && !isManuallyPaused }

    var scanProgressPercent: Int? {
        SuggestionScanProgress(checked: checkedCount, total: totalCount, unavailable: unavailableCount)
            .percentage(complete: hasScanned)
    }

    func scheduleBackgroundCheck(after delay: TimeInterval = 15 * 60) {
        guard defaults.bool(forKey: Self.backgroundEnabledKey), !isManuallyPaused else { return }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { return }
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermalState = ProcessInfo.processInfo.thermalState
        let chargingDelay = SuggestionCheckBudget.shouldPause(
            lowPowerMode: lowPowerMode,
            thermalState: thermalState,
            isCharging: true
        ) ? max(delay, PhotoSuggestionBackgroundTask.energyRetryDelay) : delay
        let batteryDelay = SuggestionCheckBudget.shouldPause(
            lowPowerMode: lowPowerMode,
            thermalState: thermalState,
            isCharging: false
        ) ? max(delay, PhotoSuggestionBackgroundTask.energyRetryDelay) : delay
        let accepted = PhotoSuggestionBackgroundTask.schedule(
            chargingAfter: chargingDelay,
            batteryAfter: batteryDelay
        )
        backgroundScheduleError = accepted ? nil : PhotoSuggestionBackgroundTask.lastSubmissionError
    }

    func runBackgroundCheck(library: PhotoLibraryService, reviews: ReviewStore) async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard backgroundCheckingEnabled, status == .authorized || status == .limited,
              !SuggestionCheckBudget.shouldPause(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                 thermalState: ProcessInfo.processInfo.thermalState,
                                                 isCharging: isCharging) else { return false }
        lastBackgroundRunDate = .now
        defaults.set(lastBackgroundRunDate, forKey: Self.lastBackgroundRunKey)
        await library.ensureLoaded()
        guard !Task.isCancelled else { return false }
        if isScanning {
            // A foreground scan can still be marked running after the app is
            // suspended. Hand its cached progress to this system-granted task
            // instead of rejecting the only background execution window.
            let foregroundWork = scanTask
            pause()
            await foregroundWork?.value
            guard !Task.isCancelled else { return false }
        }
        start(library: library, reviews: reviews, background: true)
        let work = scanTask
        await withTaskCancellationHandler {
            await work?.value
        } onCancel: {
            work?.cancel()
        }
        return !Task.isCancelled && hasScanned
    }

    func skip(_ group: CleanupSuggestion) {
        skippedIDs.insert(group.id)
        defaults.set(skippedIDs.sorted(), forKey: Self.skippedKey)
    }

    func restoreSkipped() {
        skippedIDs.removeAll()
        defaults.removeObject(forKey: Self.skippedKey)
    }

    func rememberSession(_ groups: [CleanupSuggestion], index: Int) {
        resumeGroupIDs = groups.dropFirst(index).map(\.id)
        defaults.set(resumeGroupIDs, forKey: Self.resumeKey)
    }

    private func receive(_ update: SuggestionScanUpdate, generation: UUID) {
        guard self.generation == generation else { return }
        let oldGroups = groups
        let previousProgress = SuggestionScanProgress(checked: checkedCount, total: totalCount, unavailable: unavailableCount)
        let previous = Dictionary(uniqueKeysWithValues: oldGroups.map { ($0.id, $0) })
        let incomingGroups = update.groups.map { incoming in
            guard let earlier = previous[incoming.id], earlier.aestheticEvaluationComplete,
                  !incoming.aestheticEvaluationComplete else { return incoming }
            // The full-library scan may still be working. Do not put the
            // opened group back into its "comparing" state after an explicit
            // foreground attempt has already completed.
            var merged = incoming
            merged.recommendedKeepID = earlier.recommendedKeepID
            merged.recommendationBasis = earlier.recommendationBasis
            merged.aestheticLead = earlier.aestheticLead
            merged.aestheticScores = earlier.aestheticScores
            merged.aestheticScores.merge(incoming.aestheticScores) { _, newer in newer }
            merged.aestheticEvaluationComplete = true
            return merged
        }
        groups = SuggestionGroupProgress.merge(previous: oldGroups, incoming: incomingGroups,
                                               complete: update.complete)
        checkedCount = update.checked
        unavailableCount = update.unavailable
        isVerifyingCopies = update.verifying
        if update.complete || update.paused {
            isScanning = false
            isVerifyingCopies = false
            hasScanned = update.complete
            isEnergyPaused = update.energyPaused
            if update.complete { lastScanDate = .now }
            errorMessage = update.error
            scanTask = nil
        }
        let currentProgress = SuggestionScanProgress(checked: checkedCount, total: totalCount, unavailable: unavailableCount)
        if groups != oldGroups || currentProgress != previousProgress || update.complete || update.paused {
            saveGroupSnapshot()
        }
    }

    private func saveGroupSnapshot() {
        snapshotRevision &+= 1
        let revision = snapshotRevision
        let snapshot = SuggestionGroupSnapshot(
            groups: groups, hasScanned: hasScanned, lastScanDate: lastScanDate,
            progress: SuggestionScanProgress(checked: checkedCount, total: totalCount, unavailable: unavailableCount)
        )
        let writer = snapshotWriter
        Task(priority: .utility) { [weak self] in
            let saved = await writer.save(snapshot, revision: revision)
            guard !saved else { return }
            self?.errorMessage = String(localized: "建议已生成，但未能保存到本机。下次打开时可能需要重新检查。")
        }
    }
}

enum SuggestionScanStartPolicy {
    static func shouldStart(
        manuallyPaused: Bool, isScanning: Bool, scannedRevision: Int?, currentRevision: Int,
        hasScanned: Bool, needsDailyRefresh: Bool
    ) -> Bool {
        !manuallyPaused && !isScanning &&
            (scannedRevision != currentRevision || !hasScanned || needsDailyRefresh)
    }
}

/// A scan publishes partial results. Keep valid previously discovered groups
/// visible until a complete scan can replace the full list. When a new group
/// contains any of their photos, the new classification takes precedence.
enum SuggestionGroupProgress {
    static func merge(previous: [CleanupSuggestion], incoming: [CleanupSuggestion], complete: Bool) -> [CleanupSuggestion] {
        guard !complete else { return incoming }
        let incomingGroups = Set(incoming.map(\.id))
        let incomingAssets = Set(incoming.flatMap(\.assetIDs))
        return incoming + previous.filter {
            !incomingGroups.contains($0.id) && Set($0.assetIDs).isDisjoint(with: incomingAssets)
        }
    }
}

struct SuggestionScanProgress: Codable, Equatable, Sendable {
    let checked: Int
    let total: Int
    let unavailable: Int

    static func fromCache(assets: [SuggestionAsset], analyses: [String: SuggestionAnalysis]) -> Self {
        let checkedAssets = assets.filter { asset in
            guard let analysis = analyses[asset.id], analysis.matches(asset) else { return false }
            return analysis.previewUnavailableAt != nil || !asset.isScreenshot || analysis.hasCurrentScreenshotClassification
        }
        return Self(checked: checkedAssets.count, total: assets.count,
                    unavailable: checkedAssets.count { analyses[$0.id]?.previewUnavailableAt != nil })
    }

    func percentage(complete: Bool) -> Int? {
        guard total > 0 else { return nil }
        if complete { return 100 }
        return min(99, max(0, Int((Double(checked) / Double(total) * 100).rounded(.down))))
    }
}

struct SuggestionGroupSnapshot: Codable, Sendable {
    let groups: [CleanupSuggestion]
    let hasScanned: Bool
    let lastScanDate: Date?
    let groupingVersion: Int?
    let progress: SuggestionScanProgress?

    static let currentGroupingVersion = 7

    init(groups: [CleanupSuggestion], hasScanned: Bool, lastScanDate: Date?,
         groupingVersion: Int? = currentGroupingVersion, progress: SuggestionScanProgress? = nil) {
        self.groups = groups
        self.hasScanned = hasScanned
        self.lastScanDate = lastScanDate
        self.groupingVersion = groupingVersion
        self.progress = progress
    }

    static let defaultURL = URL.applicationSupportDirectory
        .appending(path: "PhotoSuggestions", directoryHint: .isDirectory)
        .appending(path: "groups-v1.json")

    static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

private actor SuggestionGroupSnapshotWriter {
    let url: URL
    private var latestRevision = 0

    init(url: URL) { self.url = url }

    func save(_ snapshot: SuggestionGroupSnapshot, revision: Int) -> Bool {
        guard revision > latestRevision else { return true }
        latestRevision = revision
        do {
            try snapshot.save(to: url)
            return true
        } catch {
            return false
        }
    }
}

private struct SuggestionScanUpdate: Sendable {
    let groups: [CleanupSuggestion]
    let checked: Int
    let unavailable: Int
    var verifying = false
    var complete = false
    var paused = false
    var energyPaused = false
    var error: String?
}

/// PhotoKit resources and Vision observations stay on this actor. Only small
/// value snapshots cross into the UI; no image analysis runs on the main actor.
private actor PhotoSuggestionAnalyzer {
    private var analyses: [String: SuggestionAnalysis] = [:]
    /// A resource request can fail because an iCloud-only original is not
    /// available locally. Keep that result separately from the analysis model
    /// so it survives a background run without making the asset look like a
    /// duplicate or an unavailable preview.
    private var resourceVerificationFailures: [String: Date] = [:]
    private var loaded = false
    private var cacheError: String?
    private var lastCacheSave = Date.distantPast
    private let cacheURL: URL = URL.applicationSupportDirectory
        .appending(path: "PhotoSuggestions", directoryHint: .isDirectory)
        .appending(path: "analysis-v1.json")
    private let resourceFailureURL: URL = URL.applicationSupportDirectory
        .appending(path: "PhotoSuggestions", directoryHint: .isDirectory)
        .appending(path: "resource-failures-v1.json")

    func scorePriority(_ members: [SuggestionAsset]) async -> [String: SuggestionAnalysis] {
        loadCache()
        for asset in members {
            guard !Task.isCancelled else { break }
            guard let current = analyses[asset.id], current.matches(asset),
                  current.previewUnavailableAt == nil, current.aestheticScore == nil else { continue }
            let fastImage = await preview(for: asset.id, fast: true)
            let image: UIImage?
            if let fastImage, let cgImage = fastImage.cgImage,
               min(cgImage.width, cgImage.height) >= 256 {
                image = fastImage
            } else {
                // A fast local rendition can be too small for Vision. Try a
                // final local image before declaring this member unscored.
                image = await preview(for: asset.id)
            }
            let score: Float?
            if let image, !Task.isCancelled {
                score = autoreleasepool { aestheticScore(for: image) }
            } else {
                score = nil
            }
            guard !Task.isCancelled, var latest = analyses[asset.id], latest.matches(asset) else { break }
            latest.aestheticScore = score
            // A fast local rendition may be too small for Vision. Leave that
            // asset eligible for the normal high-quality pass later.
            latest.aestheticChecked = score != nil
            analyses[asset.id] = latest
        }
        let result = Dictionary(uniqueKeysWithValues: members.compactMap { member in
            analyses[member.id].map { (member.id, $0) }
        })
        if !Task.isCancelled {
            Task(priority: .utility) { self.saveCache(force: true) }
        }
        return result
    }

    func scan(_ assets: [SuggestionAsset], background: Bool, isCharging: Bool,
              progress: @Sendable (SuggestionScanUpdate) async -> Void) async {
        loadCache()
        let current = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        analyses = analyses.filter { id, analysis in
            guard let asset = current[id], analysis.matches(asset) else { return false }
            if let unavailableAt = analysis.previewUnavailableAt {
                return background && Date.now.timeIntervalSince(unavailableAt) < 24 * 3600
            }
            // Keep usable results visible while a newer classifier checks
            // them again. The loop below revisits stale versions first.
            return !asset.isScreenshot || (analysis.eventDates != nil && analysis.screenshotContentChecked == true)
        }
        // A changed asset with the same local identifier must get a fresh
        // resource attempt. Drop failure timestamps that no longer belong to
        // a retained analysis or to the current library snapshot.
        resourceVerificationFailures = resourceVerificationFailures.filter { id, _ in
            guard let asset = current[id], let analysis = analyses[id] else { return false }
            return analysis.matches(asset)
        }
        let ordered = SuggestionScanOrder.ordered(assets)
        let resumed = SuggestionScanProgress.fromCache(assets: ordered, analyses: analyses)
        var checked = resumed.checked
        var unavailable = resumed.unavailable
        var analysisFailures = 0
        var newAnalyses = 0
        let lightweightProgressStride = max(4, assets.count / 100)
        await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable))
        for asset in ordered {
            guard !Task.isCancelled else { saveCache(force: true); return }
            if analyses[asset.id] == nil ||
               (asset.isScreenshot && analyses[asset.id]?.previewUnavailableAt == nil &&
                analyses[asset.id]?.hasCurrentScreenshotClassification == false) {
                let energyPaused = SuggestionCheckBudget.shouldPause(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                                    thermalState: ProcessInfo.processInfo.thermalState,
                                                                    background: background, isCharging: isCharging)
                if energyPaused || (background && newAnalyses >= SuggestionScanPace.analysisLimit(isCharging: isCharging)) {
                    saveCache(force: true)
                    await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable,
                                                        paused: true, energyPaused: energyPaused))
                    return
                }
                if let image = await preview(for: asset.id) {
                    guard !Task.isCancelled else { saveCache(force: true); return }
                    analyses[asset.id] = autoreleasepool { analyze(image, asset: asset) }
                    if analyses[asset.id] == nil { analysisFailures += 1 }
                } else {
                    unavailable += 1
                    analyses[asset.id] = SuggestionAnalysis(asset: asset, differenceHash: 0, featurePrint: Data(),
                                                           hasPastEvent: false, previewUnavailableAt: .now)
                }
                newAnalyses += 1
                if background && !isCharging {
                    try? await Task.sleep(for: SuggestionScanPace.itemDelay(isCharging: false))
                }
                checked += 1
                let refreshGroups = checked % 48 == 0 ||
                    (asset.isScreenshot && (checked % 8 == 0 || analyses[asset.id]?.temporaryScreenshotKind != nil))
                if refreshGroups {
                    saveCache()
                    await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable))
                } else if newAnalyses % lightweightProgressStride == 0 {
                    saveCache()
                    // Keep existing groups visible; this update only advances
                    // the numeric progress without rebuilding Vision groups.
                    await progress(SuggestionScanUpdate(groups: [], checked: checked, unavailable: unavailable))
                }
            }
        }
        guard !Task.isCancelled else { saveCache(force: true); return }
        // Score only photos that actually entered a comparison group. Existing
        // feature-print caches remain usable while scores are filled in, so
        // an upgrade never empties Suggestions just to migrate the cache.
        let comparisonIDs = Set(groups(for: assets).filter { $0.kind == .similar }.flatMap(\.assetIDs))
        var newScores = 0
        for asset in ordered where comparisonIDs.contains(asset.id) && analyses[asset.id]?.aestheticChecked != true {
            guard !Task.isCancelled else { saveCache(force: true); return }
            let energyPaused = SuggestionCheckBudget.shouldPause(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                                thermalState: ProcessInfo.processInfo.thermalState,
                                                                background: background, isCharging: isCharging)
            if energyPaused || (background && newAnalyses + newScores >= SuggestionScanPace.analysisLimit(isCharging: isCharging)) {
                saveCache(force: true)
                await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable,
                                                    paused: true, energyPaused: energyPaused))
                return
            }
            if let image = await preview(for: asset.id) {
                guard !Task.isCancelled else { saveCache(force: true); return }
                analyses[asset.id]?.aestheticScore = autoreleasepool { aestheticScore(for: image) }
            }
            analyses[asset.id]?.aestheticChecked = true
            newScores += 1
            if background && !isCharging {
                try? await Task.sleep(for: SuggestionScanPace.itemDelay(isCharging: false))
            }
            if newScores % 4 == 0 {
                saveCache()
                await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable))
            }
        }
        if newScores > 0 {
            saveCache(force: true)
            await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable))
        }
        guard !Task.isCancelled else { saveCache(force: true); return }
        // Stream original resources only for visually nominated still copies.
        // Live Photos remain visual suggestions because their movie matters.
        let probable = groups(for: assets).filter { $0.reason == .possibleVersions }
        let nominated = Set(probable.flatMap(\.assetIDs))
        await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable, verifying: !nominated.isEmpty))
        var verified = 0
        let resourceCandidates = SuggestionResourceVerification.candidates(
            assets: assets,
            nominated: nominated,
            analyses: analyses,
            failures: resourceVerificationFailures,
            background: background
        )
        for asset in resourceCandidates {
            guard !Task.isCancelled else { saveCache(force: true); return }
            let energyPaused = SuggestionCheckBudget.shouldPause(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                                thermalState: ProcessInfo.processInfo.thermalState,
                                                                background: background, isCharging: isCharging)
            if energyPaused || (background && verified >= SuggestionScanPace.resourceLimit(isCharging: isCharging)) {
                saveCache(force: true)
                await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable,
                                                    paused: true, energyPaused: energyPaused))
                return
            }
            let fingerprint = await resourceFingerprint(for: asset.id)
            guard !Task.isCancelled else { saveCache(force: true); return }
            if let fingerprint {
                analyses[asset.id]?.resourceDigest = fingerprint.digest
                analyses[asset.id]?.resourceBytes = fingerprint.bytes
                analyses[asset.id]?.checkedResources = true
                resourceVerificationFailures.removeValue(forKey: asset.id)
            } else {
                // Count the failed attempt against this run's low-impact
                // budget, but remember it so the next background run advances
                // to later copies instead of retrying the same first eight.
                resourceVerificationFailures[asset.id] = .now
            }
            verified += 1
            if background && !isCharging {
                try? await Task.sleep(for: SuggestionScanPace.itemDelay(isCharging: false))
            }
            if verified % 8 == 0 {
                saveCache()
                await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable, verifying: true))
            }
        }
        guard !Task.isCancelled else { saveCache(force: true); return }
        saveCache(force: true)
        let analysisError = analysisFailures > 0
            ? String(localized: "部分照片未能完成图像分析。可更新建议重试，或继续按月份审核。") : nil
        await progress(SuggestionScanUpdate(groups: groups(for: assets), checked: checked, unavailable: unavailable, complete: true, error: analysisError ?? cacheError))
    }

    private func groups(for assets: [SuggestionAsset]) -> [CleanupSuggestion] {
        var prints: [String: VNFeaturePrintObservation] = [:]
        var distances: [String: Float] = [:]
        return SuggestionGrouping.build(assets: assets, analyses: analyses) { left, right in
            let key = [left, right].sorted().joined(separator: "\n")
            if let distance = distances[key] { return distance }
            for id in [left, right] where prints[id] == nil {
                guard let data = self.analyses[id]?.featurePrint else { return nil }
                prints[id] = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
            }
            guard let first = prints[left], let second = prints[right] else { return nil }
            var distance: Float = 1
            guard (try? first.computeDistance(&distance, to: second)) != nil else { return nil }
            distances[key] = distance
            return distance
        }
    }

    private func analyze(_ image: UIImage, asset: SuggestionAsset) -> SuggestionAnalysis? {
        guard let cgImage = image.cgImage, !Task.isCancelled else { return nil }
        let feature = VNGenerateImageFeaturePrintRequest()
        feature.revision = VNGenerateImageFeaturePrintRequestRevision2
        feature.imageCropAndScaleOption = .scaleFit
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.imageOrientation.cgOrientation, options: [:])
        let requests: [VNRequest] = asset.isScreenshot ? [text] : [feature]
        #if targetEnvironment(simulator)
        configureCPU(for: requests)
        #endif
        do {
            do {
                try handler.perform(requests)
            } catch {
                // A device may have an unavailable accelerator. Retry once on
                // supported CPU stages before reporting an analysis failure.
                configureCPU(for: requests)
                try handler.perform(requests)
            }
            let recognized = text.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            if asset.isScreenshot {
                return SuggestionAnalysis(asset: asset, differenceHash: 0, featurePrint: Data(),
                                          hasPastEvent: ScreenshotEventDate.hasPastEvent(in: recognized),
                                          eventDates: ScreenshotEventDate.eventDates(in: recognized),
                                          temporaryScreenshotKind: TemporaryScreenshotClassifier.classify(recognized),
                                          screenshotContentChecked: true,
                                          screenshotClassifierVersion: TemporaryScreenshotClassifier.version)
            }
            guard let observation = feature.results?.first,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true),
                  let hash = differenceHash(cgImage) else { return nil }
            return SuggestionAnalysis(asset: asset, differenceHash: hash, featurePrint: data,
                                      hasPastEvent: ScreenshotEventDate.hasPastEvent(in: recognized),
                                      eventDates: asset.isScreenshot ? ScreenshotEventDate.eventDates(in: recognized) : nil)
        } catch { return nil }
    }

    private func aestheticScore(for image: UIImage) -> Float? {
        guard let cgImage = image.cgImage, !Task.isCancelled else { return nil }
        let request = VNCalculateImageAestheticsScoresRequest()
        request.revision = VNCalculateImageAestheticsScoresRequestRevision1
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.imageOrientation.cgOrientation, options: [:])
        #if targetEnvironment(simulator)
        configureCPU(for: [request])
        #endif
        do {
            do { try handler.perform([request]) }
            catch {
                configureCPU(for: [request])
                try handler.perform([request])
            }
            guard let score = request.results?.first?.overallScore, score.isFinite else { return nil }
            return score
        } catch { return nil }
    }

    private func configureCPU(for requests: [VNRequest]) {
        for request in requests {
            for (stage, devices) in (try? request.supportedComputeStageDevices) ?? [:] {
                if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
    }

    private func differenceHash(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                          bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard success else { return nil }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 where pixels[row * 9 + col] > pixels[row * 9 + col + 1] {
                hash |= 1 << (row * 8 + col)
            }
        }
        return hash
    }

    private func preview(for identifier: String, fast: Bool = false) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        // Opportunistic requests can return a local thumbnail even when the
        // full-quality rendition lives only in iCloud. Keep that local result
        // for analysis without enabling a download.
        options.deliveryMode = fast ? .fastFormat : .opportunistic
        options.resizeMode = fast ? .fast : .exact
        let state = SuggestionPreviewRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                let requestID = manager.requestImage(for: asset, targetSize: CGSize(width: 640, height: 640), contentMode: .aspectFit, options: options) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    if let image {
                        if fast || !degraded {
                            state.finish(image)
                            return
                        }
                        state.offerLocalThumbnail(image)
                        if (info?[PHImageResultIsInCloudKey] as? Bool) == true { state.finish(nil) }
                    } else {
                        // A final cloud-only result may be empty. Use the
                        // degraded local thumbnail if PhotoKit supplied one.
                        state.finish(nil)
                    }
                }
                state.install(requestID, manager: manager)
                if !fast {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        state.finish(nil)
                    }
                }
            }
        } onCancel: { state.cancel(manager: manager) }
    }

    private func resourceFingerprint(for identifier: String) async -> (digest: String, bytes: Int64)? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset).sorted {
            if $0.type.rawValue != $1.type.rawValue { return $0.type.rawValue < $1.type.rawValue }
            return $0.originalFilename < $1.originalFilename
        }
        guard !resources.isEmpty else { return nil }
        var parts: [String] = []
        var bytes: Int64 = 0
        for resource in resources {
            guard !Task.isCancelled else { return nil }
            let state = SuggestionResourceRequest()
            let manager = PHAssetResourceManager.default()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            let result = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard state.install(continuation) else { return }
                    let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { state.append($0) }) { error in
                        state.finish(success: error == nil)
                    }
                    state.install(id, manager: manager)
                }
            } onCancel: { state.cancel(manager: manager) }
            guard let result else { return nil }
            parts.append("\(resource.type.rawValue):\(resource.contentType.identifier):\(result.digest)")
            bytes += result.bytes
        }
        let digest = SHA256.hash(data: Data(parts.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return (digest, bytes)
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: cacheURL) {
            if let cached = SuggestionAnalysisCache.decode(data) {
                analyses = cached
            } else {
                cacheError = String(localized: "旧的建议分析缓存无法读取，正在重新检查照片。")
            }
        }
        if let data = try? Data(contentsOf: resourceFailureURL),
           let cached = try? JSONDecoder().decode([String: Date].self, from: data) {
            resourceVerificationFailures = cached
        }
    }

    private func saveCache(force: Bool = false) {
        guard force || Date.now.timeIntervalSince(lastCacheSave) > 30 else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(analyses).write(to: cacheURL, options: .atomic)
            try JSONEncoder().encode(resourceVerificationFailures).write(to: resourceFailureURL, options: .atomic)
            cacheError = nil
            lastCacheSave = .now
        } catch {
            cacheError = String(localized: "建议已生成，但分析缓存未能保存。下次可能需要重新分析。")
        }
    }
}

/// Older app builds may omit fields that are now required by Swift's
/// synthesized Codable initializer. Recover entries independently instead of
/// dropping every analysis when a single row cannot be decoded.
enum SuggestionAnalysisCache {
    static func decode(_ data: Data) -> [String: SuggestionAnalysis]? {
        let decoder = JSONDecoder()
        if let cached = try? decoder.decode([String: SuggestionAnalysis].self, from: data) { return cached }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        var recovered: [String: SuggestionAnalysis] = [:]
        recovered.reserveCapacity(raw.count)
        for (id, value) in raw {
            var entry = value
            // `checkedResources` was added after the first analysis cache
            // format. It defaults to false for files written before then.
            if entry["checkedResources"] == nil { entry["checkedResources"] = false }
            guard let encoded = try? JSONSerialization.data(withJSONObject: entry),
                  let analysis = try? decoder.decode(SuggestionAnalysis.self, from: encoded) else { continue }
            recovered[id] = analysis
        }
        return recovered.isEmpty && !raw.isEmpty ? nil : recovered
    }
}

enum SuggestionScanOrder {
    static func ordered(_ assets: [SuggestionAsset], now: Date = .now) -> [SuggestionAsset] {
        let screenshotCutoff = now.addingTimeInterval(-90 * 86_400)
        let candidates = assets.filter { !$0.isScreenshot || ($0.createdAt ?? .distantFuture) < screenshotCutoff }

        func interleaved(_ candidates: [SuggestionAsset]) -> [SuggestionAsset] {
            let screenshots = candidates.filter(\.isScreenshot).sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            let photos = candidates.filter { !$0.isScreenshot }.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
            var result: [SuggestionAsset] = []
            result.reserveCapacity(candidates.count)
            var screenshotIndex = 0
            var photoIndex = 0
            while screenshotIndex < screenshots.count || photoIndex < photos.count {
                // Give old screenshots an early turn, but do not let a large
                // screenshot library postpone every similar-photo group.
                if screenshotIndex < screenshots.count {
                    result.append(screenshots[screenshotIndex])
                    screenshotIndex += 1
                }
                for _ in 0..<4 where photoIndex < photos.count {
                    result.append(photos[photoIndex])
                    photoIndex += 1
                }
            }
            return result
        }
        return interleaved(candidates.filter(\.isEligible)) + interleaved(candidates.filter { !$0.isEligible })
    }
}

/// Chooses resource-verification work without letting unavailable originals
/// starve later copies in background runs. Foreground refreshes intentionally
/// retry immediately because the user explicitly requested new results.
enum SuggestionResourceVerification {
    static let failureCooldown: TimeInterval = 6 * 60 * 60

    static func candidates(
        assets: [SuggestionAsset],
        nominated: Set<String>,
        analyses: [String: SuggestionAnalysis],
        failures: [String: Date],
        background: Bool,
        now: Date = .now
    ) -> [SuggestionAsset] {
        assets.filter { asset in
            guard nominated.contains(asset.id), !asset.isLivePhoto,
                  let analysis = analyses[asset.id], !analysis.checkedResources else { return false }
            guard background, let failedAt = failures[asset.id] else { return true }
            return now.timeIntervalSince(failedAt) >= failureCooldown
        }
    }
}

enum ScreenshotEventDate {
    static func hasPastEvent(in text: String, now: Date = .now) -> Bool {
        eventDates(in: text).contains {
            Calendar.current.date(byAdding: .day, value: 1, to: $0).map { $0 < now } ?? false
        }
    }

    static func eventDates(in text: String) -> [Date] {
        let keywords = ["活动", "演出", "音乐会", "入场", "开场", "报名", "event", "concert", "admission", "showtime"]
        guard keywords.contains(where: { text.localizedCaseInsensitiveContains($0) }),
              let regex = try? NSRegularExpression(pattern: "(?<![0-9])(20[0-9]{2})[年./-]\\s*([0-9]{1,2})[月./-]\\s*([0-9]{1,2})(?![0-9])") else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let numbers = (1...3).compactMap { Int(source.substring(with: match.range(at: $0))) }
            guard numbers.count == 3, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]),
                  let date = Calendar.current.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2])),
                  Calendar.current.component(.month, from: date) == numbers[1],
                  Calendar.current.component(.day, from: date) == numbers[2] else { return nil }
            return date
        }
    }
}

private extension UIImage.Orientation {
    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

final class SuggestionPreviewRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?
    private var localThumbnail: UIImage?
    private var finished = false

    func install(_ continuation: CheckedContinuation<UIImage?, Never>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(returning: nil); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    func install(_ id: PHImageRequestID, manager: PHImageManager) {
        lock.lock(); requestID = id; let cancel = finished; lock.unlock()
        if cancel { manager.cancelImageRequest(id) }
    }
    func offerLocalThumbnail(_ image: UIImage) {
        guard let pixels = image.cgImage,
              max(pixels.width, pixels.height) >= 320,
              min(pixels.width, pixels.height) >= 160 else { return }
        lock.lock()
        if !finished { localThumbnail = image }
        lock.unlock()
    }
    func finish(_ image: UIImage?, useLocalThumbnail: Bool = true) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result = image ?? (useLocalThumbnail ? localThumbnail : nil)
        localThumbnail = nil
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
    func cancel(manager: PHImageManager) {
        lock.lock(); let id = requestID; lock.unlock()
        finish(nil, useLocalThumbnail: false)
        if let id { manager.cancelImageRequest(id) }
    }
}

private struct ResourceFingerprint: Sendable { let digest: String; let bytes: Int64 }

private final class SuggestionResourceRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ResourceFingerprint?, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var finished = false
    private var hasher = SHA256()
    private var bytes: Int64 = 0

    func install(_ continuation: CheckedContinuation<ResourceFingerprint?, Never>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(returning: nil); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        hasher.update(data: data); bytes += Int64(data.count)
    }
    func install(_ id: PHAssetResourceDataRequestID, manager: PHAssetResourceManager) {
        lock.lock(); requestID = id; let cancel = finished; lock.unlock()
        if cancel { manager.cancelDataRequest(id) }
    }
    func finish(success: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let result = success && bytes > 0 ? ResourceFingerprint(digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes) : nil
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
    func cancel(manager: PHAssetResourceManager) {
        lock.lock(); let id = requestID; lock.unlock()
        finish(success: false)
        if let id { manager.cancelDataRequest(id) }
    }
}
