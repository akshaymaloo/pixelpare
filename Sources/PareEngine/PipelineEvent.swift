import Foundation
import PareCore

public enum PipelineStep: String, Codable, Sendable, Equatable {
    case preflight, download, encode, verify, importCopy, verifyImported, remove
}

public enum WaitReason: Sendable, Equatable {
    case network
    case expensiveNetwork
    case diskSpace(needed: Int64)
    case thermal
    case lowPower
    case backoff(until: Date)
    case paused

    public var message: String {
        switch self {
        case .network: "Waiting for an internet connection"
        case .expensiveNetwork: "Waiting for Wi‑Fi (cellular and Low Data Mode are off in settings)"
        case .diskSpace: "Waiting for free storage"
        case .thermal: "Waiting for the device to cool down"
        case .lowPower: "Paused while Low Power Mode is on"
        case .backoff: "Retrying shortly"
        case .paused: "Paused"
        }
    }
}

public enum JobOutcome: Sendable, Equatable {
    case awaitingRemovalApproval(newID: MediaID, savedBytes: Int64)
    case skipped(String)
    case failed(String, ErrorClass)
    case cancelled
    case removed
}

public enum PipelineEvent: Sendable, Equatable {
    case queued(MediaID)
    case stateChanged(MediaID, OperationJournal.State)
    case progress(MediaID, PipelineStep, Double)
    case waiting(MediaID, WaitReason)
    case resumed(MediaID)
    case retrying(MediaID, PipelineStep, attempt: Int, after: TimeInterval, reason: String)
    case finished(MediaID, JobOutcome)
    case paused
    case resumedAll
    case idle
}

/// Fan-out of events to any number of `AsyncStream` subscribers. Safe to call from any thread.
final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PipelineEvent>.Continuation] = [:]

    func stream() -> AsyncStream<PipelineEvent> {
        let (stream, cont) = AsyncStream<PipelineEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        lock.lock(); continuations[id] = cont; lock.unlock()
        cont.onTermination = { [weak self] _ in
            self?.lock.lock(); self?.continuations[id] = nil; self?.lock.unlock()
        }
        return stream
    }

    func send(_ event: PipelineEvent) {
        lock.lock(); let all = Array(continuations.values); lock.unlock()
        for c in all { c.yield(event) }
    }

    func finishAll() {
        lock.lock(); let all = Array(continuations.values); continuations = [:]; lock.unlock()
        for c in all { c.finish() }
    }
}
