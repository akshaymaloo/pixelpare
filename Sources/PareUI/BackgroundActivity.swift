import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the process running while long work (scan, video run) is in flight.
/// macOS: `ProcessInfo.beginActivity` (no App Nap / idle sleep).
/// iOS: keeps the screen from auto-locking while any activity is open, and holds a UIApplication background-task
/// assertion so a short trip out of the app doesn't suspend an encode mid-way. When that grace period expires the
/// assertion is released; the pipeline is journaled, so an interrupted job resumes on the next run.
/// TODO(iOS): adopt BGContinuedProcessingTask (iOS 26) so long batches keep going with system progress UI; that
/// needs an identifier in BGTaskSchedulerPermittedIdentifiers and a scheduler hand-off from the foreground UI.
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
