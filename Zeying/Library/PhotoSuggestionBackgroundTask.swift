@preconcurrency import BackgroundTasks
import Foundation
import OSLog
import UIKit

/// iOS chooses an idle window. Never keep the app alive with a timer
/// or download a cloud original in order to finish a suggestion check.
@MainActor
enum PhotoSuggestionBackgroundTask {
    static let identifier = "com.mars.zeying.photo-suggestions"
    static let chargingIdentifier = "com.mars.zeying.photo-suggestions-charging"
    static let normalRetryDelay: TimeInterval = 15 * 60
    /// If the system has already told us to pause, a short retry loop only
    /// wakes the app repeatedly while the same thermal/power condition holds.
    static let energyRetryDelay: TimeInterval = 6 * 60 * 60
    static let successfulScanDelay: TimeInterval = 12 * 60 * 60
    private static var registrationAttempted = false
    private static var registered = false
    private static var activeRun: Run?
    private static let logger = Logger(subsystem: "com.mars.zeying", category: "PhotoSuggestionsBackground")
    private(set) static var lastSubmissionError: String?

    static func retryDelay(success: Bool, energyPaused: Bool, isCharging: Bool = false) -> TimeInterval {
        if success { return successfulScanDelay }
        if energyPaused { return energyRetryDelay }
        return isCharging ? 0 : normalRetryDelay
    }

    static func register(service: PhotoSuggestionService, library: PhotoLibraryService, reviews: ReviewStore) {
        guard !registrationAttempted else { return }
        registrationAttempted = true
        var allRegistered = true
        for taskIdentifier in [identifier, chargingIdentifier] {
            let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
                MainActor.assumeIsolated {
                    guard let processing = task as? BGProcessingTask,
                          UIApplication.shared.applicationState != .active,
                          activeRun == nil else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    let run = Run(task: processing, service: service)
                    activeRun = run
                    run.start(library: library, reviews: reviews)
                }
            }
            allRegistered = allRegistered && accepted
        }
        registered = allRegistered
        if !allRegistered { logger.error("Photo suggestion background task registration failed") }
    }

    // Keep the default literal outside the actor-isolated constant lookup;
    // callers that need a named policy use `normalRetryDelay` explicitly.
    @discardableResult
    static func schedule(chargingAfter chargingDelay: TimeInterval,
                         batteryAfter batteryDelay: TimeInterval) -> Bool {
        guard registered else {
            lastSubmissionError = String(localized: "后台检查尚未准备好；打开应用时仍会继续检查。")
            return false
        }
        var accepted = false
        for (taskIdentifier, requiresPower, delay) in [
            (chargingIdentifier, true, chargingDelay),
            (identifier, false, batteryDelay)
        ] {
            let request = BGProcessingTaskRequest(identifier: taskIdentifier)
            request.requiresNetworkConnectivity = false
            request.requiresExternalPower = requiresPower
            request.earliestBeginDate = delay > 0 ? Date.now.addingTimeInterval(delay) : nil
            do {
                // Submitting the same identifier replaces its pending request.
                try BGTaskScheduler.shared.submit(request)
                accepted = true
                logger.info("Photo suggestion request submitted; external power required: \(requiresPower)")
            } catch {
                logger.error("Photo suggestion request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !accepted {
            lastSubmissionError = String(localized: "iOS 暂未接受后台检查任务；打开应用时仍会继续检查。")
        } else {
            lastSubmissionError = nil
        }
        return accepted
    }

    static func cancelPending() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: chargingIdentifier)
    }
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
            // The short foreground allowance must not expire and cancel a
            // system-granted processing run that starts soon after backgrounding.
            PhotoSuggestionForegroundGrace.end()
            logger.info("Photo suggestion background run started; charging: \(self.service.isCharging)")
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
            logger.info("Photo suggestion background run finished; complete: \(success), checked: \(self.service.checkedCount)")
            work = nil
            activeRun = nil
            let energyPaused = SuggestionCheckBudget.shouldPause(
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState,
                isCharging: service.isCharging
            )
            service.scheduleBackgroundCheck(after: PhotoSuggestionBackgroundTask.retryDelay(
                success: success,
                energyPaused: energyPaused,
                isCharging: service.isCharging
            ))
        }
    }
}
