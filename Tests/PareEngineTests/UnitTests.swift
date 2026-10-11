import AVFoundation
import Foundation
import PareCore
import PareEngine
import PareLibrary
import PareTranscode
import Testing

@Suite("ErrorClassifier")
struct ErrorClassifierTests {
    func c(_ e: Error) -> ErrorClass { ErrorClassifier.classify(e) }
    func photos(_ code: Int) -> Error { PhotosErrorCodes.error(code) }

    @Test func urlErrors() {
        #expect(c(URLError(.notConnectedToInternet)) == .waitNetwork)
        #expect(c(URLError(.dataNotAllowed)) == .waitNetwork)
        #expect(c(URLError(.timedOut)) == .transient)
        #expect(c(URLError(.networkConnectionLost)) == .transient)
        #expect(c(URLError(.cancelled)) == .cancelled)
    }

    @Test func photoKitErrors() {
        #expect(c(photos(PhotosErrorCodes.userCancelled)) == .userDeclined)
        #expect(c(photos(PhotosErrorCodes.networkAccessRequired)) == .waitNetwork)
        #expect(c(photos(PhotosErrorCodes.networkError)) == .waitNetwork)
        #expect(c(photos(PhotosErrorCodes.notEnoughSpace)) == .waitDisk)
        #expect(c(photos(PhotosErrorCodes.accessUserDenied)) == .needsUser)
        #expect(c(photos(PhotosErrorCodes.accessRestricted)) == .needsUser)
        #expect(c(photos(PhotosErrorCodes.invalidResource)) == .permanent)
        #expect(c(photos(PhotosErrorCodes.identifierNotFound)) == .permanent)
        #expect(c(photos(PhotosErrorCodes.operationInterrupted)) == .transient)
        #expect(c(photos(PhotosErrorCodes.switchingSystemPhotoLibrary)) == .transient)
    }

    @Test func avFoundationErrors() {
        func av(_ code: AVError.Code) -> Error { NSError(domain: AVFoundationErrorDomain, code: code.rawValue) }
        #expect(c(av(.diskFull)) == .waitDisk)
        #expect(c(av(.decodeFailed)) == .permanent)
        #expect(c(av(.fileFormatNotRecognized)) == .permanent)
        #expect(c(av(.unknown)) == .transient)
    }

    @Test func fileSystemErrors() {
        #expect(c(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .waitDisk)
        #expect(c(NSError(domain: NSCocoaErrorDomain, code: 640)) == .waitDisk)
        #expect(c(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .needsUser)
        #expect(c(CocoaError(.fileWriteNoPermission)) == .needsUser)
        #expect(c(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))) == .transient)
    }

    @Test func ownErrorsAndUnknowns() {
        #expect(c(TranscodeError.cannotConfigure("x")) == .permanent)
        #expect(c(TranscodeError.noVideoTrack) == .permanent)
        #expect(c(TranscodeError.writerFailed("x")) == .transient)
        #expect(c(LibraryError.accessDenied) == .needsUser)
        #expect(c(LibraryError.notFound("x")) == .permanent)
        #expect(c(CancellationError()) == .cancelled)
        #expect(c(StallError(step: "download")) == .transient)
        #expect(c(PipelineError.copyMismatch("x")) == .permanent)
        #expect(c(NSError(domain: "whatever", code: 42)) == .transient)
    }

    @Test func messagesAreHumanReadable() {
        #expect(!ErrorClassifier.message(for: URLError(.notConnectedToInternet)).isEmpty)
        #expect(ErrorClassifier.message(for: StallError(step: "encode")).contains("encode"))
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test func ceilingDoublesAndIsCapped() {
        let p = RetryPolicy(maxAttempts: 10, base: 2, cap: 30)
        #expect(p.ceiling(forAttempt: 1) == 2)
        #expect(p.ceiling(forAttempt: 2) == 4)
        #expect(p.ceiling(forAttempt: 4) == 16)
        #expect(p.ceiling(forAttempt: 5) == 30)
        #expect(p.ceiling(forAttempt: 500) == 30)
    }

    @Test func fullJitterStaysInsideTheWindowAndIsSeededDeterministically() {
        let p = RetryPolicy(maxAttempts: 10, base: 2, cap: 300)
        var a = SplitMix64(seed: 7), b = SplitMix64(seed: 7)
        var seen = Set<Double>()
        for attempt in 1...8 {
            let x = p.delay(forAttempt: attempt, using: &a)
            #expect(x == p.delay(forAttempt: attempt, using: &b))
            #expect(x >= 0 && x <= p.ceiling(forAttempt: attempt))
            seen.insert(x)
        }
        #expect(seen.count > 4)
    }

    @Test func attemptBudget() {
        let p = RetryPolicy(maxAttempts: 3)
        #expect(p.shouldRetry(afterAttempt: 1) && p.shouldRetry(afterAttempt: 2) && !p.shouldRetry(afterAttempt: 3))
    }
}

@Suite("StallWatchdog")
struct StallWatchdogTests {
    @Test func progressKeepsABusyBodyAlive() async throws {
        let w = StallWatchdog(step: "t", timeout: .milliseconds(300), grace: .milliseconds(20))
        let v = try await w.run { touch in
            for _ in 0..<12 { try await Task.sleep(for: .milliseconds(50)); touch() }
            return 7
        }
        #expect(v == 7)
    }

    @Test func silenceThrowsStallErrorAndCancelsTheBody() async throws {
        let w = StallWatchdog(step: "encode", timeout: .milliseconds(100), grace: .milliseconds(20))
        let cancelled = Counter()
        await #expect(throws: StallError.self) {
            try await w.run { _ in
                do { try await Task.sleep(for: .seconds(30)) } catch { _ = cancelled.next(); throw error }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(cancelled.value == 1)
    }

    @Test func aBodyThatIgnoresCancellationIsAbandonedAfterGrace() async throws {
        let w = StallWatchdog(step: "t", timeout: .milliseconds(80), grace: .milliseconds(50))
        let start = ContinuousClock.now
        await #expect(throws: StallError.self) {
            try await w.run { _ -> Int in
                while true { try? await Task.sleep(for: .milliseconds(10)) }   // never rethrows
            }
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func callerCancellationPropagates() async throws {
        let w = StallWatchdog(step: "t", timeout: .seconds(30), grace: .milliseconds(20))
        let task = Task { try await w.run { _ in try await Task.sleep(for: .seconds(30)); return 1 } }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test func bodyErrorsPassThrough() async throws {
        let w = StallWatchdog(step: "t", timeout: .seconds(5), grace: .milliseconds(20))
        await #expect(throws: Boom.self) { try await w.run { _ in throw Boom() } as Int }
    }
}

@Suite("JobWorkspace")
struct JobWorkspaceTests {
    @Test func layoutBackupExclusionAndCleanup() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = JobWorkspace(root: dir.appendingPathComponent("Jobs"))
        let id = MediaID("a/b.mov")
        let job = try ws.prepare(for: id)
        #expect(job == ws.directory(for: id))
        let values = try ws.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(ws.encodedPartialURL(for: id).lastPathComponent == "encoded.mov.partial")
        #expect(ws.directory(for: id) != ws.directory(for: MediaID("a/c.mov")))

        try Data([1, 2]).write(to: ws.finalSourceURL(for: id, ext: "mov"))
        try Data([1]).write(to: job.appendingPathComponent("source.mp4.partial"))
        #expect(ws.sourceURL(for: id)?.lastPathComponent == "source.mov")   // partials never count
        ws.removePartials(for: id)
        #expect(!FileManager.default.fileExists(atPath: job.appendingPathComponent("source.mp4.partial").path))
        ws.cleanup(for: id)
        #expect(ws.sourceURL(for: id) == nil)
        #expect(ws.isEmptyOfJobs)
    }

    @Test func garbageCollectionKeepsOnlyListedJobs() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = JobWorkspace(root: dir.appendingPathComponent("Jobs"))
        let a = MediaID("a"), b = MediaID("b")
        try ws.prepare(for: a); try ws.prepare(for: b)
        let removed = ws.collectGarbage(keeping: [a])
        #expect(removed.count == 1)
        #expect(FileManager.default.fileExists(atPath: ws.directory(for: a).path))
        #expect(!FileManager.default.fileExists(atPath: ws.directory(for: b).path))
    }

    @Test func lockIsExclusiveAndReleasable() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = JobWorkspace(root: dir.appendingPathComponent("Jobs"))
        let first = try ws.acquireLock()
        #expect(throws: PipelineError.workspaceLocked) { try ws.acquireLock() }
        first.release()
        let second = try ws.acquireLock()
        second.release()
        // The lock file itself is never garbage-collected.
        _ = ws.collectGarbage(keeping: [])
        #expect(FileManager.default.fileExists(atPath: ws.root.appendingPathComponent(".lock").path))
    }
}

@Suite("Conditions")
struct ConditionsTests {
    @Test func realImplementationsAnswer() {
        #expect(SystemDiskSpace().availableBytes(at: FileManager.default.temporaryDirectory.appendingPathComponent("nope/deeper")) != nil)
        _ = SystemDeviceConditions().thermalState
        _ = SystemNetworkMonitor().status()
    }
}
