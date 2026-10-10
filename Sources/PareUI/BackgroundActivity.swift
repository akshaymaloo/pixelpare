import Foundation
#if canImport(UIKit)
import BackgroundTasks
import UIKit
#endif

/// Keeps the process running while long work (scan, video run) is in flight.
/// macOS: `ProcessInfo.beginActivity` (no App Nap / idle sleep).
/// iOS: keeps the screen from auto-locking while any activity is open, and holds a UIApplication background-task
/// assertion so a short trip out of the app doesn't suspend an encode mid-way. When that grace period expires the
/// assertion is released; the pipeline is journaled, so an interrupted job resumes on the next run.
/// A video run additionally hands itself to `ContinuedRun` (BGContinuedProcessingTask, iOS 26), so it keeps going
/// in the background with system progress UI. The system can still expire it (low battery, thermal pressure, the
/// user cancelling it); the run then pauses cleanly and resumes next time.
@MainActor
final class BackgroundActivity {
    #if os(macOS)
    private var token: NSObjectProtocol?
    init(_ reason: String) {
        token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }
    func end() {
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
    }
    #elseif canImport(UIKit)
    private static var open = 0
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var ended = false
    init(_ reason: String) {
        Self.open += 1
        UIApplication.shared.isIdleTimerDisabled = true
        task = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            MainActor.assumeIsolated { self?.releaseTask() }
        }
    }
    private func releaseTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
    func end() {
        guard !ended else { return }
        ended = true
        releaseTask()
        Self.open -= 1
        if Self.open == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
    #else
    init(_ reason: String) {}
    func end() {}
    #endif
}

/// A user-started run registered as a `BGContinuedProcessingTask`. If the system refuses the request (simulator,
/// too much load) this is inert and the run relies on `BackgroundActivity` alone. macOS: always inert.
@MainActor
final class ContinuedRun {
    #if os(iOS)
    static let identifierPrefix = "com.akshaymaloo.pixelpare.run."
    private final class TaskBox: @unchecked Sendable { let task: BGContinuedProcessingTask; init(_ t: BGContinuedProcessingTask) { task = t } }
    private let identifier = ContinuedRun.identifierPrefix + UUID().uuidString
    private var task: BGContinuedProcessingTask?
    private var submitted = false
    private var finished = false
    private var completed = 0, total = 0
    private var subtitle = ""
    private let onExpire: @MainActor () async -> Void

    /// `onExpire` must stop the work promptly (the journal makes that safe).
    init(title: String, subtitle: String, total: Int, onExpire: @escaping @MainActor () async -> Void) {
        self.onExpire = onExpire; self.total = total; self.subtitle = subtitle
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] t in
            let box = TaskBox(t as! BGContinuedProcessingTask)
            MainActor.assumeIsolated { self?.started(box.task) }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request); submitted = true } catch { submitted = false }
    }

    private func started(_ t: BGContinuedProcessingTask) {
        guard !finished else { t.setTaskCompleted(success: true); return }
        task = t
        t.expirationHandler = { [weak self] in
            Task { @MainActor in await self?.expired() }
        }
        apply()
    }

    private func expired() async {
        guard let t = task, !finished else { return }
        await onExpire()
        finished = true; task = nil
        t.setTaskCompleted(success: false)
    }

    private func apply() {
        guard let t = task else { return }
        t.progress.totalUnitCount = Int64(max(total, 1))
        t.progress.completedUnitCount = Int64(min(completed, max(total, 1)))
        t.updateTitle(t.title, subtitle: subtitle)
    }

    func update(completed: Int, total: Int, subtitle: String) {
        self.completed = completed; self.total = total; self.subtitle = subtitle
        apply()
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if let t = task { t.setTaskCompleted(success: success) }
        else if submitted { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        task = nil
    }
    #else
    init(title: String, subtitle: String, total: Int, onExpire: @escaping @MainActor () async -> Void) {}
    func update(completed: Int, total: Int, subtitle: String) {}
    func finish(success: Bool) {}
    #endif
}
