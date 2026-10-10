import Foundation

/// Allows one hardware encode session per process (FIFO, cancellation-aware).
/// Overlapping and cancelled VideoToolbox sessions kernel-panicked macOS 27.0.1 on an M3 Pro/Max
/// (`dart-ave0 … PTE invalid exception`), so full transcodes and preview clips never run concurrently.
public actor EncoderGate {
    public static let shared = EncoderGate()

    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public func withExclusiveAccess<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                waiters.append((id, c))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    /// Ownership passes directly to the next waiter, so `busy` stays true while anyone is queued.
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume() }
    }
}
