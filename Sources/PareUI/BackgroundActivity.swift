import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the process running while long work is in flight.
/// macOS: `ProcessInfo.beginActivity` (no App Nap / idle sleep). iOS: a UIApplication background-task assertion.
/// TODO(iOS): adopt BGContinuedProcessingTask (iOS 26) with a BGContinuedProcessingTaskRequest so long batches
/// continue with system progress UI; that needs a registered identifier in BGTaskSchedulerPermittedIdentifiers
/// and a scheduler hand-off from the foreground UI, so it is left out of this stage.
struct BackgroundActivity: @unchecked Sendable {
    #if os(macOS)
    private let token: NSObjectProtocol
    static func begin(_ reason: String) async -> BackgroundActivity {
        BackgroundActivity(token: ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: reason))
    }
    func end() { ProcessInfo.processInfo.endActivity(token) }
    #elseif canImport(UIKit)
    private let id: UIBackgroundTaskIdentifier
    static func begin(_ reason: String) async -> BackgroundActivity {
        let id = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: reason, expirationHandler: nil) }
        return BackgroundActivity(id: id)
    }
    func end() {
        let id = id
        Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
    }
    #else
    static func begin(_ reason: String) async -> BackgroundActivity { BackgroundActivity() }
    func end() {}
    #endif
}
