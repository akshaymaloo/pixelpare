import Foundation
import PareCore
import PareLibrary
import PareTranscode

public struct PipelineConfig: Sendable {
    public var downloadStall: Duration = .seconds(120)
    public var encodeStall: Duration = .seconds(60)
    public var stallGrace: Duration = .seconds(5)
    /// An encode that saves less than this fraction of the original is skipped (docs/resilience.md §4).
    public var minSavings = 0.15
    /// Free space kept in reserve on top of what a job needs.
    public var diskHeadroom: Int64 = 1_000_000_000
    public var allowExpensiveNetwork = true
    public var pollInterval: TimeInterval = 5
    public var removalBatchSize = 50
    public var retryDownload = RetryPolicy.download
    public var retryEncode = RetryPolicy.encode
    public var retryImport = RetryPolicy.importCopy
    public var retryGeneric = RetryPolicy.generic
    public var verifyImported = RetryPolicy.verifyImported
    public var encodeAttemptsPerRung = 2
    public init() {}
}

public struct RemovalResult: Sendable, Equatable {
    public var removed: [MediaID] = []
    /// The user declined the system delete prompt; originals are untouched and still awaiting approval.
    public var declined: [MediaID] = []
    /// Not attempted, because an invariant check failed (reason attached).
    public var refused: [MediaID: String] = [:]
    /// Attempted and failed; the original is still present.
    public var failed: [MediaID: String] = [:]
    public init() {}
}

/// The resilient compress-and-replace pipeline of docs/resilience.md. A serial queue of jobs, each driven by its
/// journal state so that every step is idempotent and resumable after a crash, relaunch or interruption.
public actor VideoPipeline {
    public typealias TransitionHook = @Sendable (OperationJournal.Entry) throws -> Void

    enum ProcessEnd { case done, interrupted, crashed }

    let library: any MediaLibrary
    let journal: OperationJournal
    let workspace: JobWorkspace
    let encoder: any VideoEncoding
    let network: any NetworkMonitoring
    let disk: any DiskSpaceProviding
    let device: any DeviceConditions
    let clock: any PipelineClock
    var config: PipelineConfig
    var rng: AnyRandomNumberGenerator
    let afterTransition: TransitionHook?
    let hub = EventHub()

    var lock: WorkspaceLock?
    var queue: [MediaID] = []
    var runner: Task<Void, Never>?
    var currentID: MediaID?
    var currentTask: Task<ProcessEnd, Never>?
    var paused = false
    var crashed = false
    var removalInProgress = false
    var held: Set<MediaID> = []
    var cancelled: Set<MediaID> = []
    var lastState: [MediaID: OperationJournal.State] = [:]
    var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(library: any MediaLibrary, journal: OperationJournal, workspace: JobWorkspace,
                encoder: any VideoEncoding = DefaultVideoEncoder(),
                network: any NetworkMonitoring = SystemNetworkMonitor(),
                disk: any DiskSpaceProviding = SystemDiskSpace(),
                device: any DeviceConditions = SystemDeviceConditions(),
                clock: any PipelineClock = SystemClock(),
                config: PipelineConfig = PipelineConfig(),
                rng: AnyRandomNumberGenerator = AnyRandomNumberGenerator(),
                afterTransition: TransitionHook? = nil) {
        self.library = library; self.journal = journal; self.workspace = workspace; self.encoder = encoder
        self.network = network; self.disk = disk; self.device = device; self.clock = clock
        self.config = config; self.rng = rng; self.afterTransition = afterTransition
    }

    // MARK: Public API

    public nonisolated func events() -> AsyncStream<PipelineEvent> { hub.stream() }

    /// Takes the workspace lock, settles whatever a previous run left behind and (unless `autoResume` is false)
    /// restarts unfinished jobs. Call once at launch.
    public func recover(autoResume: Bool = true) async throws {
        try acquireLock()
        for e in await journal.entries() where e.state == .removing {
            switch await lookup(e.original) {
            case .gone: try? await commit(e.original) { $0.state = .removed }
            case .present: try? await commit(e.original) { $0.state = .awaitingRemovalApproval }
            case .unknown: break   // only a definite answer settles the entry
            }
        }
        let entries = await journal.entries()
        let inFlight = entries.filter { Self.isInFlight($0.state) }
        workspace.collectGarbage(keeping: Set(inFlight.map(\.original)))
        for e in inFlight where !queue.contains(e.original) && e.original != currentID { queue.append(e.original) }
        paused = !autoResume   // held until `resume()` when the caller wants to confirm first
        kick()
    }

    /// Adds videos to the queue. Jobs already in flight, awaiting approval or removed are left alone;
    /// skipped and failed ones start over.
    public func enqueue(_ items: [MediaItem], preset: VideoPreset) async throws {
        do { try await enqueueItems(items, preset: preset) } catch let c as SimulatedCrash { crash(); throw c }
    }

    private func enqueueItems(_ items: [MediaItem], preset: VideoPreset) async throws {
        try acquireLock()
        for item in items {
            if let e = await journal.entry(for: item.id), Self.isInFlight(e.state) || e.state == .removed
                || e.state == .awaitingRemovalApproval || e.state == .removing { continue }
            let mod = item.modificationDate
            try await commit(item.id) { e in
                e.state = .planned; e.preset = preset; e.originalModificationDate = mod
                e.settings = nil; e.newID = nil; e.attempts = [:]; e.lastError = nil; e.nextRetryAt = nil
                e.encodeRung = 0; e.encodedBytes = nil
                e.importToken = nil; e.importStartedAt = nil
                e.duration = nil; e.encodedWidth = nil; e.encodedHeight = nil
            }
            cancelled.remove(item.id)
            if !queue.contains(item.id) && currentID != item.id { queue.append(item.id) }
            hub.send(.queued(item.id))
        }
        kick()
    }

    public func pause() {
        guard !paused else { return }
        paused = true
        currentTask?.cancel()
        hub.send(.paused)
    }

    public func resume() {
        guard paused else { return }
        paused = false
        hub.send(.resumedAll)
        kick()
    }

    /// Stops a job for good and clears its scratch files. A copy that was already imported is kept and will be
    /// adopted if the video is enqueued again.
    public func cancel(_ id: MediaID) async {
        cancelled.insert(id)
        queue.removeAll { $0 == id }
        if currentID == id, let t = currentTask { t.cancel(); _ = await t.value }
        guard !crashed, let e = await journal.entry(for: id),
              !e.state.isTerminal, e.state != .awaitingRemovalApproval, e.state != .removing else { return }
        try? await commit(id) {
            $0.state = .failed; $0.lastError = .init(kind: ErrorClass.cancelled.rawValue, message: "Cancelled")
        }
        workspace.cleanup(for: id)
        hub.send(.finished(id, .cancelled))
    }

    /// Keeps recovered jobs out of the queue until the caller releases them. Used so unfinished jobs from a
    /// previous session only run after the user accepts them.
    public func hold(_ ids: Set<MediaID>) {
        held.formUnion(ids)
        queue.removeAll { ids.contains($0) }
    }

    /// Puts held jobs back in the queue (they run once the pipeline is resumed).
    public func release(_ ids: Set<MediaID>) async {
        for id in ids.sorted() where held.contains(id) {
            held.remove(id)
            guard let e = await journal.entry(for: id), Self.isInFlight(e.state) else { continue }
            if !queue.contains(id) && currentID != id { queue.append(id) }
        }
        kick()
    }

    /// Re-queues a failed or skipped job. With a verified-but-unconfirmed copy it resumes at verification.
    public func retry(_ id: MediaID) async throws {
        try acquireLock()
        guard let e = await journal.entry(for: id), e.state == .failed || e.state == .skipped else { return }
        let resumeAtVerify = e.newID != nil
        try await commit(id) {
            $0.state = resumeAtVerify ? .imported : .planned
            $0.attempts = [:]; $0.lastError = nil; $0.nextRetryAt = nil; $0.encodeRung = 0
        }
        cancelled.remove(id)
        if !queue.contains(id) && currentID != id { queue.append(id) }
        hub.send(.queued(id))
        kick()
    }

    /// Returns once nothing is running (or the pipeline is paused/crashed).
    public func waitUntilIdle() async {
        if runner == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func shutdown() async {
        paused = true
        currentTask?.cancel()
        queue.removeAll()
        if let r = runner { await r.value }
        lock?.release(); lock = nil
        hub.finishAll()
    }

    // MARK: Queue

    public static func isInFlight(_ s: OperationJournal.State) -> Bool {
        switch s {
        case .planned, .preflight, .downloading, .downloaded, .encoding, .encoded, .verified, .importing, .imported:
            true
        case .awaitingRemovalApproval, .removing, .removed, .skipped, .failed: false
        }
    }

    enum Lookup { case present, gone, unknown }

    func lookup(_ id: MediaID) async -> Lookup {
        do { return try await library.item(id) == nil ? .gone : .present } catch { return .unknown }
    }

    func acquireLock() throws {
        if crashed { throw SimulatedCrash() }
        if lock == nil { lock = try workspace.acquireLock() }
    }

    func kick() {
        guard runner == nil, !paused, !crashed, !queue.isEmpty else { return }
        runner = Task { await self.runLoop() }
    }

    private func runLoop() async {
        while !paused, !crashed, !queue.isEmpty {
            let id = queue.removeFirst()
            currentID = id
            let task = Task { await self.process(id) }
            currentTask = task
            let end = await task.value
            currentTask = nil; currentID = nil
            switch end {
            case .done: break
            case .interrupted: if !cancelled.contains(id) { queue.insert(id, at: 0) }
            case .crashed: crash()
            }
        }
        runner = nil
        if !crashed && queue.isEmpty { hub.send(.idle) }
        let waiters = idleWaiters
        idleWaiters = []
        for w in waiters { w.resume() }
    }

    /// Simulates the process dying: nothing else is written and the lock goes away, as it would with the process.
    func crash() {
        crashed = true
        queue.removeAll()
        lock?.release(); lock = nil
    }

    // MARK: Journal

    func commit(_ id: MediaID, _ mutate: @Sendable (inout OperationJournal.Entry) -> Void) async throws {
        try await commitEntry(id, mutate)
    }

    @discardableResult
    func commitEntry(_ id: MediaID, _ mutate: @Sendable (inout OperationJournal.Entry) -> Void) async throws
        -> OperationJournal.Entry {
        if crashed { throw SimulatedCrash() }
        let e = try await journal.update(id, now: clock.now(), mutate)
        if lastState[id] != e.state {
            lastState[id] = e.state
            hub.send(.stateChanged(id, e.state))
        }
        try afterTransition?(e)
        return e
    }

    func skip(_ id: MediaID, _ reason: String) async throws {
        try await commit(id) { $0.state = .skipped; $0.lastError = .init(kind: "skipped", message: reason) }
        workspace.cleanup(for: id)
        hub.send(.finished(id, .skipped(reason)))
    }

    func fail(_ id: MediaID, _ cls: ErrorClass, _ message: String) async throws {
        try await commit(id) { $0.state = .failed; $0.lastError = .init(kind: cls.rawValue, message: message) }
        workspace.cleanup(for: id)
        hub.send(.finished(id, .failed(message, cls)))
    }

    // MARK: Job driver

    func process(_ id: MediaID) async -> ProcessEnd {
        while true {
            do {
                try Task.checkCancellation()
                if crashed { return .crashed }
                guard let e = await journal.entry(for: id) else { return .done }
                if !Self.isInFlight(e.state) { return .done }
                try await step(e)
            } catch {
                switch await handle(error, id: id) {
                case .retry: continue
                case .stop: return .done
                case .interrupted: return .interrupted
                case .crashed: return .crashed
                }
            }
        }
    }

    enum Handling { case retry, stop, interrupted, crashed }

    static func stepKey(_ s: OperationJournal.State) -> String {
        switch s {
        case .planned, .preflight: "preflight"
        case .downloading, .downloaded: "download"
        case .encoding: "encode"
        case .encoded: "verify"
        case .verified, .importing: "import"
        case .imported: "verifyImported"
        default: "other"
        }
    }

    func policy(for key: String) -> RetryPolicy {
        switch key {
        case "download": config.retryDownload
        case "encode": config.retryEncode
        case "import": config.retryImport
        case "verifyImported": config.verifyImported
        default: config.retryGeneric
        }
    }

    /// The one place that turns an error into a decision (§6).
    func handle(_ error: Error, id: MediaID) async -> Handling {
        if error is SimulatedCrash { return .crashed }
        if crashed { return .crashed }
        guard let entry = await journal.entry(for: id) else { return .stop }
        let cls = ErrorClassifier.classify(error)
        let message = ErrorClassifier.message(for: error)
        let key = Self.stepKey(entry.state)
        do {
            if cls == .cancelled || (error is CancellationError) {
                if cancelled.contains(id) { return .stop }
                if paused || Task.isCancelled { return .interrupted }
                return try await backoff(id, key: key, reason: message)
            }
            switch cls {
            case .waitNetwork:
                if !network.status().isConnected {
                    try await waitUntil(id, .network) { network.status().isConnected }
                    return .retry
                }
                return try await backoff(id, key: key, reason: message)
            case .waitDisk:
                let needed = (entry.sourceBytes ?? 0) + config.diskHeadroom
                if let avail = disk.availableBytes(at: workspace.root), avail < needed {
                    try await waitUntil(id, .diskSpace(needed: needed)) {
                        (disk.availableBytes(at: workspace.root) ?? .max) >= needed
                    }
                    return .retry
                }
                return try await backoff(id, key: key, reason: message)
            case .transient:
                return try await backoff(id, key: key, reason: message)
            case .permanent, .needsUser, .userDeclined:
                try await fail(id, cls, message)
                return .stop
            case .cancelled:
                return .stop
            }
        } catch is SimulatedCrash {
            return .crashed
        } catch {
            return cancelled.contains(id) ? .stop : (paused || Task.isCancelled ? .interrupted : .stop)
        }
    }

    /// Counts the attempt, journals when the next one is due, sleeps (with jitter), and asks for a retry. Fails the
    /// job once the step's budget is spent.
    func backoff(_ id: MediaID, key: String, reason: String) async throws -> Handling {
        let p = policy(for: key)
        let attempt = try await commitEntry(id) { e in
            e.attempts[key] = (e.attempts[key] ?? 0) + 1
            e.lastError = .init(kind: ErrorClass.transient.rawValue, message: reason)
        }.attempts[key] ?? 1
        if !p.shouldRetry(afterAttempt: attempt) {
            try await fail(id, .transient, reason)
            return .stop
        }
        let delay = p.delay(forAttempt: attempt, using: &rng)
        let due = clock.now().addingTimeInterval(delay)
        try await commit(id) { $0.nextRetryAt = due }
        hub.send(.retrying(id, Self.pipelineStep(key), attempt: attempt, after: delay, reason: reason))
        hub.send(.waiting(id, .backoff(until: due)))
        try await clock.sleep(for: delay)
        try await commit(id) { $0.nextRetryAt = nil }
        hub.send(.resumed(id))
        return .retry
    }

    static func pipelineStep(_ key: String) -> PipelineStep {
        switch key {
        case "download": .download
        case "encode": .encode
        case "verify": .verify
        case "import": .importCopy
        case "verifyImported": .verifyImported
        default: .preflight
        }
    }

    /// Polls `ok` on the pipeline clock; not an error and not counted as an attempt.
    func waitUntil(_ id: MediaID, _ reason: WaitReason, _ ok: () -> Bool) async throws {
        if ok() { return }
        hub.send(.waiting(id, reason))
        var n = 0.0
        while !ok() {
            try await clock.sleep(for: min(config.pollInterval * 3, config.pollInterval + n))
            n += 1
        }
        hub.send(.resumed(id))
    }

    func ensureDisk(_ id: MediaID, needed: Int64) async throws {
        try await waitUntil(id, .diskSpace(needed: needed)) {
            (disk.availableBytes(at: workspace.root) ?? .max) >= needed
        }
    }

    func isUnchanged(_ item: MediaItem, _ entry: OperationJournal.Entry) -> Bool {
        // Without a recorded date an edit can't be detected (I1), so treat the original as changed.
        guard let was = entry.originalModificationDate, let now = item.modificationDate else { return false }
        return now == was
    }
}
