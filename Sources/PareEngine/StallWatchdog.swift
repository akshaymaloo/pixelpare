import Foundation

/// Cancels work that stops reporting progress. Uses real time (not the pipeline clock): a stall is a property of
/// the wall clock, so virtual-time tests configure short real timeouts instead.
public struct StallWatchdog: Sendable {
    public var step: String
    public var timeout: Duration
    /// How long a cancelled body may take to unwind before it is abandoned.
    public var grace: Duration

    public init(step: String, timeout: Duration, grace: Duration = .seconds(5)) {
        self.step = step; self.timeout = timeout; self.grace = grace
    }

    /// Runs `body`, which must call `touch` whenever it makes progress. Throws `StallError` after `timeout`
    /// without progress; the body is cancelled and, if it ignores cancellation, abandoned after `grace`.
    /// Cancelling the caller cancels the body the same way.
    public func run<T: Sendable>(
        _ body: @escaping @Sendable (_ touch: @escaping @Sendable () -> Void) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let channel = Channel<T>(step: step)
        let touch: @Sendable () -> Void = { channel.touch() }
        let timeout = timeout, grace = grace
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                channel.install(cont)
                let worker = Task {
                    do { channel.finish(.success(try await body(touch))) }
                    catch { channel.finish(.failure(error)) }
                }
                let monitor = Task {
                    let tick = max(timeout / 4, .milliseconds(5))
                    while !Task.isCancelled {
                        try? await Task.sleep(for: tick)
                        if Task.isCancelled { return }
                        if channel.idle() >= timeout {
                            channel.markStalled()
                            worker.cancel()
                            try? await Task.sleep(for: grace)
                            channel.finish(.failure(StallError(step: channel.step)))
                            return
                        }
                    }
                }
                channel.attach(worker: worker, monitor: monitor)
            }
        } onCancel: {
            channel.cancel(grace: grace)
        }
    }

    private final class Channel<T: Sendable>: @unchecked Sendable {
        let step: String
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        private var finished = false
        private var stalled = false
        private var lastProgress = ContinuousClock.now
        private var worker: Task<Void, Never>?
        private var monitor: Task<Void, Never>?
        private var cancelRequested = false

        init(step: String) { self.step = step }

        func touch() { lock.lock(); lastProgress = .now; lock.unlock() }
        func idle() -> Duration { lock.lock(); defer { lock.unlock() }; return ContinuousClock.now - lastProgress }
        func markStalled() { lock.lock(); stalled = true; lock.unlock() }

        func install(_ c: CheckedContinuation<T, Error>) {
            lock.lock()
            if let r = result { lock.unlock(); c.resume(with: r); return }
            cont = c
            lock.unlock()
        }

        func attach(worker: Task<Void, Never>, monitor: Task<Void, Never>) {
            lock.lock()
            self.worker = worker; self.monitor = monitor
            let cancel = cancelRequested
            lock.unlock()
            if cancel { worker.cancel(); monitor.cancel() }
        }

        func finish(_ r: Result<T, Error>) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            var out = r
            // A body cancelled because of a stall reports CancellationError; the stall is the real cause.
            if stalled, case .failure = r { out = .failure(StallError(step: step)) }
            result = out
            let c = cont; cont = nil
            let m = monitor
            lock.unlock()
            m?.cancel()
            c?.resume(with: out)
        }

        func cancel(grace: Duration) {
            lock.lock()
            cancelRequested = true
            let (w, m) = (worker, monitor)
            lock.unlock()
            w?.cancel(); m?.cancel()
            Task { [self] in
                try? await Task.sleep(for: grace)
                finish(.failure(CancellationError()))
            }
        }
    }
}
