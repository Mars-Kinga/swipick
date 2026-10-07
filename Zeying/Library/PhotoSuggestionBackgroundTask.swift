@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit

/// iOS chooses an idle window. Never keep the app alive with a timer
/// or download a cloud original in order to finish a suggestion check.
@MainActor
enum PhotoSuggestionBackgroundTask {
    static let identifier = "com.mars.zeying.photo-suggestions"
    static let normalRetryDelay: TimeInterval = 15 * 60
    /// If the system has already told us to pause, a short retry loop only
    /// wakes the app repeatedly while the same thermal/power condition holds.
    static let energyRetryDelay: TimeInterval = 6 * 60 * 60
    static let successfulScanDelay: TimeInterval = 12 * 60 * 60
    private static var registered = false
    private static var activeRun: Run?
    private static let logger = Logger(subsystem: "com.mars.zeying", category: "PhotoSuggestionsBackground")
    private(set) static var lastSubmissionError: String?

    static func retryDelay(success: Bool, energyPaused: Bool) -> TimeInterval {
        if success { return successfulScanDelay }
        return energyPaused ? energyRetryDelay : normalRetryDelay
    }

    static func register(service: PhotoSuggestionService, library: PhotoLibraryService, reviews: ReviewStore) {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask, UIApplication.shared.applicationState != .active else {
                    task.setTaskCompleted(success: false)
                    return
                }
                let run = Run(task: processing, service: service)
                activeRun = run
                run.start(library: library, reviews: reviews)
            }
        }
    }

    // Keep the default literal outside the actor-isolated constant lookup;
    // callers that need a named policy use `normalRetryDelay` explicitly.
    @discardableResult
    static func schedule(after delay: TimeInterval = 15 * 60) -> Bool {
        guard registered else {
            lastSubmissionError = String(localized: "后台检查尚未准备好；打开应用时仍会继续检查。")
            return false
        }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        // The analyzer already stops for Low Power Mode / thermal pressure and
        // caps each background pass, so battery use need not block scheduling.
        request.requiresExternalPower = false
        // An unfinished foreground scan may resume at the next idle window.
        // A nil earliest date removes our former 15-minute minimum delay;
        // iOS still chooses the actual launch time.
        request.earliestBeginDate = delay > 0 ? Date.now.addingTimeInterval(delay) : nil
        // Replacing the same identifier updates the request without enqueuing
        // another scan. Background refresh may be disabled by the user/system.
        do {
            try BGTaskScheduler.shared.submit(request)
            lastSubmissionError = nil
            logger.info("Photo suggestion background request submitted")
            return true
        } catch {
            logger.error("Photo suggestion background request failed: \(error.localizedDescription, privacy: .public)")
            lastSubmissionError = String(localized: "iOS 暂未接受后台检查任务；打开应用时仍会继续检查。")
            return false
        }
    }

    static func cancelPending() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
    static func cancelRunning() { activeRun?.cancel() }

    @MainActor
    private final class Run {
        let task: BGProcessingTask
        let service: PhotoSuggestionService
        var work: Task<Void, Never>?
        var finished = false

        init(task: BGProcessingTask, service: PhotoSuggestionService) {
            self.task = task
            self.service = service
            task.expirationHandler = { [weak self] in
                Task { @MainActor in self?.cancel() }
            }
        }

        func start(library: PhotoLibraryService, reviews: ReviewStore) {
            work = Task(priority: .background) { [weak self] in
                guard let self else { return }
                let complete = await service.runBackgroundCheck(library: library, reviews: reviews)
                finish(success: complete)
            }
        }

        func cancel() {
            guard !finished else { return }
            work?.cancel()
            service.pause()
            finish(success: false)
        }

        private func finish(success: Bool) {
            guard !finished else { return }
            finished = true
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
            work = nil
            activeRun = nil
            let energyPaused = SuggestionCheckBudget.shouldPause(
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState
            )
            service.scheduleBackgroundCheck(after: PhotoSuggestionBackgroundTask.retryDelay(
                success: success,
                energyPaused: energyPaused
            ))
        }
    }
}
