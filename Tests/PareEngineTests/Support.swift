import CoreGraphics
import Foundation
import PareCore
import PareEngine
import PareLibrary
import PareTranscode

// MARK: Clock, randomness, conditions

final class VirtualClock: PipelineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [TimeInterval] = []
    var onSleep: (@Sendable (Int) -> Void)?

    func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let (n, cb) = advance(seconds)
        cb?(n)
        await Task.yield()
        try Task.checkCancellation()
    }

    private func advance(_ seconds: TimeInterval) -> (Int, (@Sendable (Int) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        time = time.addingTimeInterval(seconds)
        sleeps.append(seconds)
        return (sleeps.count, onSleep)
    }

    var sleepCount: Int { lock.lock(); defer { lock.unlock() }; return sleeps.count }
}

struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class FakeNetwork: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value = NetworkStatus.online
    func status() -> NetworkStatus { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ s: NetworkStatus) { lock.lock(); value = s; lock.unlock() }
}

final class FakeDisk: DiskSpaceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64? = 500_000_000_000
    func availableBytes(at url: URL) -> Int64? { lock.lock(); defer { lock.unlock() }; return bytes }
    func set(_ b: Int64?) { lock.lock(); bytes = b; lock.unlock() }
}

final class FakeDevice: DeviceConditions, @unchecked Sendable {
    private let lock = NSLock()
    private var thermal = ProcessInfo.ThermalState.nominal
    private var lowPower = false
    var thermalState: ProcessInfo.ThermalState { lock.lock(); defer { lock.unlock() }; return thermal }
    var isLowPowerModeEnabled: Bool { lock.lock(); defer { lock.unlock() }; return lowPower }
    func set(thermal t: ProcessInfo.ThermalState? = nil, lowPower l: Bool? = nil) {
        lock.lock(); if let t { thermal = t }; if let l { lowPower = l }; lock.unlock()
    }
}

// MARK: Library

/// An in-memory library with scriptable failures. Files are sparse so "100 MB" videos cost nothing.
final class FakeLibrary: MediaLibrary, @unchecked Sendable {
    private let lock = NSLock()
    private var assets: [MediaID: MediaItem] = [:]
    private var counter = 0

    // Scripts: each entry is consumed once, in order.
    var exportErrors: [Error] = []
    var importErrorsBefore: [Error] = []
    /// Created, then fails: `SimulatedCrash` here models dying between the PhotoKit commit and the journal write.
    var importErrorsAfterCommit: [Error] = []
    var itemErrors: [Error] = []
    var deleteScripts: [DeleteScript] = []
    /// After the next import completes, the new asset silently disappears (iCloud / user action).
    var vanishNextImport = false
    var modifyOnExport = false
    var authorizationValue = LibraryAccess.full
    var exportDelay: Duration?

    enum DeleteScript: Sendable {
        case userCancels
        case failsWithoutDeleting(Error)
        case deletesFirstThenFails(count: Int, Error)
        case deletesButReportsFailure(Error)
    }

    private(set) var createdCopies: [MediaID: [MediaID]] = [:]   // original -> every copy ever created
    private(set) var deleteCalls: [[MediaID]] = []
    private(set) var exportCount = 0
    private(set) var importCount = 0
    /// Called with the ids just before they are deleted; used to audit invariant I1.
    var beforeDelete: (@Sendable ([MediaID]) async -> Void)?

    func add(_ item: MediaItem) { lock.lock(); assets[item.id] = item; lock.unlock() }
    func remove(_ id: MediaID) { lock.lock(); assets[id] = nil; lock.unlock() }
    func modify(_ id: MediaID, by seconds: TimeInterval = 60) {
        lock.lock()
        let base = assets[id]?.modificationDate ?? Date()
        assets[id]?.modificationDate = base.addingTimeInterval(seconds)
        lock.unlock()
    }
    func snapshot() -> [MediaID: MediaItem] { lock.lock(); defer { lock.unlock() }; return assets }
    func has(_ id: MediaID) -> Bool { lock.lock(); defer { lock.unlock() }; return assets[id] != nil }
    func liveCopies(of original: MediaID) -> [MediaID] {
        lock.lock(); defer { lock.unlock() }
        return (createdCopies[original] ?? []).filter { assets[$0] != nil }
    }

    private func bump(_ k: ReferenceWritableKeyPath<FakeLibrary, Int>) {
        lock.lock(); self[keyPath: k] += 1; lock.unlock()
    }

    private func create(copyOf original: MediaItem, size: Int64) -> (MediaID, Bool) {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let id = MediaID("copy-\(counter)")
        assets[id] = MediaItem(id: id, kind: .video, creationDate: original.creationDate,
                               pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight, byteSize: size,
                               isLocal: true, duration: original.duration, videoCodec: "hvc1",
                               frameRate: original.frameRate, modificationDate: Date())
        createdCopies[original.id, default: []].append(id)
        let vanish = vanishNextImport
        vanishNextImport = false
        return (id, vanish)
    }

    private func recordDelete(_ ids: [MediaID]) { lock.lock(); deleteCalls.append(ids); lock.unlock() }

    private func pop<T>(_ keyPath: ReferenceWritableKeyPath<FakeLibrary, [T]>) -> T? {
        lock.lock(); defer { lock.unlock() }
        return self[keyPath: keyPath].isEmpty ? nil : self[keyPath: keyPath].removeFirst()
    }

    func authorization() async -> LibraryAccess { authorizationValue }
    func requestAccess() async -> LibraryAccess { authorizationValue }
    func items() async throws -> [MediaItem] { snapshot().values.sorted { $0.id < $1.id } }

    func item(_ id: MediaID) async throws -> MediaItem? {
        if let e = pop(\.itemErrors) { throw e }
        return snapshot()[id]
    }

    func resourceSize(_ id: MediaID) async -> Int64? { snapshot()[id]?.byteSize }
    func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage { throw LibraryError.thumbnailFailed }
    func exactHash(_ id: MediaID) async throws -> String? { nil }

    func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool,
                     progress: @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        bump(\.exportCount)
        if modifyOnExport { modifyOnExport = false; modify(id) }
        if let delay = exportDelay { try await Task.sleep(for: delay) }
        if let e = pop(\.exportErrors) { throw e }
        guard let item = snapshot()[id] else { throw LibraryError.notFound(id.raw) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("clip.mov")
        let partial = dest.appendingPathExtension("partial")
        try Self.sparse(partial, size: item.byteSize ?? 1)
        progress(0.5)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: partial, to: dest)
        progress(1)
        return dest
    }

    func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID {
        try Task.checkCancellation()
        bump(\.importCount)
        if let e = pop(\.importErrorsBefore) { throw e }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let (id, vanish) = create(copyOf: original, size: size)
        if vanish { remove(id) }
        if let e = pop(\.importErrorsAfterCommit) { throw e }
        return id
    }

    func findImportedCopy(fingerprint: ImportFingerprint, addedAfter: Date,
                          excluding: Set<MediaID>) async throws -> MediaID? {
        snapshot().values.sorted { $0.id < $1.id }.first { !excluding.contains($0.id) && fingerprint.matches($0) }?.id
    }

    func delete(_ ids: [MediaID]) async throws {
        recordDelete(ids)
        await beforeDelete?(ids)
        switch pop(\.deleteScripts) {
        case .userCancels: throw PhotosErrorCodes.error(PhotosErrorCodes.userCancelled)
        case .failsWithoutDeleting(let e): throw e
        case .deletesFirstThenFails(let n, let e):
            for id in ids.prefix(n) { remove(id) }
            throw e
        case .deletesButReportsFailure(let e):
            for id in ids { remove(id) }
            throw e
        case nil:
            for id in ids { remove(id) }
        }
    }

    static func sparse(_ url: URL, size: Int64) throws {
        let fd = open(url.path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: Encoder

final class FakeEncoder: VideoEncoding, @unchecked Sendable {
    private let lock = NSLock()
    var ratio = 0.4
    /// Consumed per encode call: nil entry = succeed.
    var encodeScript: [Error?] = []
    /// Consumed per verify call; `true` = report a correctness failure.
    var verifyFailures: [Bool] = []
    var hangFirstEncodes = 0
    private(set) var encodeRungs: [EncodeRung] = []
    private(set) var encodeCalls = 0
    private(set) var verifyCalls = 0

    private func beginEncode(_ rung: EncodeRung) -> (Bool, Error??) {
        lock.lock(); defer { lock.unlock() }
        encodeCalls += 1
        encodeRungs.append(rung)
        let hang = hangFirstEncodes > 0
        if hang { hangFirstEncodes -= 1 }
        return (hang, encodeScript.isEmpty ? .none : .some(encodeScript.removeFirst()))
    }

    private func beginVerify() -> Bool {
        lock.lock(); defer { lock.unlock() }
        verifyCalls += 1
        return verifyFailures.isEmpty ? false : verifyFailures.removeFirst()
    }

    func probe(_ url: URL) async -> SourceProbe? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0 ? SourceProbe(duration: 10, bytes: size) : nil
    }

    func encode(source: URL, output: URL, settings: EncodeSettings, rung: EncodeRung,
                progress: @Sendable (Double) -> Void) async throws {
        let (hang, scripted) = beginEncode(rung)
        if hang { try await Task.sleep(for: .seconds(60)) }
        if case .some(.some(let e)) = scripted { throw e }
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        try FakeLibrary.sparse(output, size: Int64(Double(size) * ratio))
        progress(1)
    }

    func verify(source: URL, encoded: URL, settings: EncodeSettings, preset: VideoPreset) async throws -> EncodeVerification {
        let fail = beginVerify()
        let o = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        let e = (try? FileManager.default.attributesOfItem(atPath: encoded.path)[.size] as? NSNumber)?.int64Value ?? 0
        return EncodeVerification(passed: !fail, failures: fail ? ["scripted failure"] : [], originalBytes: o,
                                  encodedBytes: e, savingsFraction: o > 0 ? 1 - Double(e) / Double(o) : 0,
                                  displayWidth: settings.width, displayHeight: settings.height)
    }
}

// MARK: Fixtures and rig

let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

func makeVideo(_ n: Int, bytes: Int64 = 100_000_000) -> MediaItem {
    MediaItem(id: MediaID("video-\(n)"), kind: .video, creationDate: baseDate.addingTimeInterval(Double(n) * 3600),
              pixelWidth: 1920, pixelHeight: 1080, byteSize: bytes, isLocal: true, duration: 10,
              videoCodec: "avc1", frameRate: 30, modificationDate: baseDate.addingTimeInterval(Double(n) * 3600 + 5))
}

func scratchDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pare-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct Boom: Error {}

/// Everything that outlives a simulated crash: the library, journal file, workspace, and fakes.
final class Rig: @unchecked Sendable {
    let dir: URL
    let library = FakeLibrary()
    let encoder = FakeEncoder()
    let network = FakeNetwork()
    let disk = FakeDisk()
    let device = FakeDevice()
    let clock = VirtualClock()
    let journalURL: URL
    let workspace: JobWorkspace
    var config = PipelineConfig()
    var seed: UInt64 = 1

    init() throws {
        dir = try scratchDir()
        journalURL = dir.appendingPathComponent("journal.json")
        workspace = JobWorkspace(root: dir.appendingPathComponent("Jobs", isDirectory: true))
        config.stallGrace = .milliseconds(20)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func journal() -> OperationJournal { OperationJournal(url: journalURL) }

    func pipeline(hook: VideoPipeline.TransitionHook? = nil) -> VideoPipeline {
        seed &+= 1
        return VideoPipeline(library: library, journal: journal(), workspace: workspace, encoder: encoder,
                             network: network, disk: disk, device: device, clock: clock, config: config,
                             rng: AnyRandomNumberGenerator(SplitMix64(seed: seed)), afterTransition: hook)
    }

    func entry(_ id: MediaID) async -> OperationJournal.Entry? { await journal().entry(for: id) }

    /// Runs one video to rest on a fresh pipeline.
    func run(_ items: [MediaItem], preset: VideoPreset = .balanced, hook: VideoPipeline.TransitionHook? = nil) async throws -> VideoPipeline {
        for i in items { library.add(i) }
        let p = pipeline(hook: hook)
        try await p.enqueue(items, preset: preset)
        await p.waitUntilIdle()
        return p
    }
}

/// Audits invariant I1 at the moment of deletion: every id handed to `delete` must be journaled as `removing`,
/// have a live, plausible new copy, and be unmodified since the job began.
final class DeleteAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String] = []
    var violations: [String] { lock.lock(); defer { lock.unlock() }; return found }
    func add(_ v: String) { lock.lock(); found.append(v); lock.unlock() }

    static func install(on rig: Rig) -> DeleteAudit {
        let audit = DeleteAudit()
        let lib = rig.library, url = rig.journalURL
        lib.beforeDelete = { ids in
            let journal = OperationJournal(url: url)
            for id in ids {
                guard let e = await journal.entry(for: id) else { audit.add("\(id.raw): no journal entry"); continue }
                if e.state != .removing { audit.add("\(id.raw): state \(e.state) at delete") }
                guard let copy = e.newID, let item = lib.snapshot()[copy] else {
                    audit.add("\(id.raw): new copy missing at delete"); continue
                }
                if (item.byteSize ?? 0) <= 0 { audit.add("\(id.raw): new copy has no size") }
                if let orig = lib.snapshot()[id], orig.modificationDate != e.originalModificationDate {
                    audit.add("\(id.raw): original modified at delete")
                }
            }
        }
        return audit
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Thread-safe event recorder.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PipelineEvent] = []
    var events: [PipelineEvent] { lock.lock(); defer { lock.unlock() }; return items }
    func record(_ e: PipelineEvent) { lock.lock(); items.append(e); lock.unlock() }
    static func collect(_ p: VideoPipeline) -> EventLog {
        let log = EventLog()
        let stream = p.events()
        Task { for await e in stream { log.record(e) } }
        return log
    }
}
