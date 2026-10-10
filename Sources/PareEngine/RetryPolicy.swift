import Foundation

/// Time source and sleeper, injectable so tests run on virtual time.
public protocol PipelineClock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemClock: PipelineClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, seconds)))
    }
}

/// Type-erased, injectable random source (seeded in tests).
public struct AnyRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var base: any RandomNumberGenerator & Sendable
    public init(_ base: any RandomNumberGenerator & Sendable) { self.base = base }
    public init() { self.base = SystemRandomNumberGenerator() }
    public mutating func next() -> UInt64 { base.next() }
}

/// Exponential backoff with full jitter: the delay for attempt n is uniform in 0…min(cap, base·2ⁿ⁻¹).
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var base: TimeInterval
    public var cap: TimeInterval

    public init(maxAttempts: Int, base: TimeInterval = 2, cap: TimeInterval = 300) {
        self.maxAttempts = maxAttempts; self.base = base; self.cap = cap
    }

    public static let download = RetryPolicy(maxAttempts: 6)
    public static let encode = RetryPolicy(maxAttempts: 2)
    public static let importCopy = RetryPolicy(maxAttempts: 4)
    public static let verifyImported = RetryPolicy(maxAttempts: 3, base: 1, cap: 10)
    public static let generic = RetryPolicy(maxAttempts: 3)

    /// Upper bound of the jitter window for a 1-based attempt number.
    public func ceiling(forAttempt attempt: Int) -> TimeInterval {
        let exp = min(max(attempt - 1, 0), 30)
        return min(cap, base * pow(2, Double(exp)))
    }

    public func delay<G: RandomNumberGenerator>(forAttempt attempt: Int, using rng: inout G) -> TimeInterval {
        let c = ceiling(forAttempt: attempt)
        return c > 0 ? Double.random(in: 0...c, using: &rng) : 0
    }

    public func shouldRetry(afterAttempt attempt: Int) -> Bool { attempt < maxAttempts }
}
