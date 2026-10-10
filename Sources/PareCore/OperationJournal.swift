import Foundation

/// Durable per-original job record (file format v2, see docs/resilience.md §3).
/// Every write is an atomic file replace; v1 files are migrated on load.
public actor OperationJournal {
    public enum State: String, Codable, Sendable, CaseIterable {
        case planned, preflight, downloading, downloaded, encoding, encoded, verified
        case importing, imported, awaitingRemovalApproval, removing, removed
        case skipped, failed

        /// v1 names kept as aliases so older call sites keep their meaning.
        public static let exported = State.downloaded
        public static let importVerified = State.awaitingRemovalApproval

        /// Terminal states; `failed` and `skipped` can be left only by an explicit user retry.
        public var isTerminal: Bool { self == .removed || self == .skipped || self == .failed }
        /// States in which the job is waiting for the user, or finished.
        public var isResting: Bool { self == .awaitingRemovalApproval || isTerminal }
    }

    public struct JobError: Codable, Sendable, Equatable {
        public var kind: String
        public var message: String
        public init(kind: String, message: String) { self.kind = kind; self.message = message }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var original: MediaID
        public var state: State
        public var preset: VideoPreset?
        public var settings: EncodeSettings?
        public var newID: MediaID?
        public var importToken: String?
        public var importStartedAt: Date?
        /// Attempts per step key (e.g. "download", "encode", "import").
        public var attempts: [String: Int]
        public var lastError: JobError?
        public var nextRetryAt: Date?
        public var sourceBytes: Int64?
        public var encodedBytes: Int64?
        public var originalModificationDate: Date?
        public var updatedAt: Date
        /// Index into the encoder fallback ladder.
        public var encodeRung: Int
        /// Duration of the exported source, and display size of the verified encode; used to fingerprint the copy.
        public var duration: TimeInterval?
        public var encodedWidth: Int?
        public var encodedHeight: Int?

        public var error: String? { lastError?.message }

        public init(original: MediaID, state: State = .planned, preset: VideoPreset? = nil,
                    settings: EncodeSettings? = nil, newID: MediaID? = nil, importToken: String? = nil,
                    importStartedAt: Date? = nil, attempts: [String: Int] = [:], lastError: JobError? = nil,
                    nextRetryAt: Date? = nil, sourceBytes: Int64? = nil, encodedBytes: Int64? = nil,
                    originalModificationDate: Date? = nil, updatedAt: Date = Date(), encodeRung: Int = 0,
                    duration: TimeInterval? = nil, encodedWidth: Int? = nil, encodedHeight: Int? = nil) {
            self.original = original; self.state = state; self.preset = preset; self.settings = settings
            self.newID = newID; self.importToken = importToken; self.importStartedAt = importStartedAt
            self.attempts = attempts; self.lastError = lastError; self.nextRetryAt = nextRetryAt
            self.sourceBytes = sourceBytes; self.encodedBytes = encodedBytes
            self.originalModificationDate = originalModificationDate; self.updatedAt = updatedAt
            self.encodeRung = encodeRung; self.duration = duration
            self.encodedWidth = encodedWidth; self.encodedHeight = encodedHeight
        }

        private enum CodingKeys: String, CodingKey {
            case original, state, preset, settings, newID, importToken, importStartedAt, attempts, lastError
            case nextRetryAt, sourceBytes, encodedBytes, originalModificationDate, updatedAt, encodeRung
            case duration, encodedWidth, encodedHeight
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            original = try c.decode(MediaID.self, forKey: .original)
            state = (try? c.decode(State.self, forKey: .state)) ?? .planned
            preset = try c.decodeIfPresent(VideoPreset.self, forKey: .preset)
            settings = try c.decodeIfPresent(EncodeSettings.self, forKey: .settings)
            newID = try c.decodeIfPresent(MediaID.self, forKey: .newID)
            importToken = try c.decodeIfPresent(String.self, forKey: .importToken)
            importStartedAt = try c.decodeIfPresent(Date.self, forKey: .importStartedAt)
            attempts = try c.decodeIfPresent([String: Int].self, forKey: .attempts) ?? [:]
            lastError = try c.decodeIfPresent(JobError.self, forKey: .lastError)
            nextRetryAt = try c.decodeIfPresent(Date.self, forKey: .nextRetryAt)
            sourceBytes = try c.decodeIfPresent(Int64.self, forKey: .sourceBytes)
            encodedBytes = try c.decodeIfPresent(Int64.self, forKey: .encodedBytes)
            originalModificationDate = try c.decodeIfPresent(Date.self, forKey: .originalModificationDate)
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
            encodeRung = try c.decodeIfPresent(Int.self, forKey: .encodeRung) ?? 0
            duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
            encodedWidth = try c.decodeIfPresent(Int.self, forKey: .encodedWidth)
            encodedHeight = try c.decodeIfPresent(Int.self, forKey: .encodedHeight)
        }
    }

    public static let currentVersion = 2

    private struct Header: Decodable { var version: Int? }
    private struct FileFormat: Codable { var version = OperationJournal.currentVersion; var entries: [Entry] }

    private struct V1Entry: Decodable {
        var original: MediaID
        var state: String
        var newID: MediaID?
        var error: String?
        var updatedAt: Date?
    }
    private struct V1File: Decodable { var entries: [V1Entry] }

    private let url: URL
    private var store: [Entry]

    /// Loads existing entries. v1 files are migrated (the old file is kept as `<name>.v1`); an unreadable file is
    /// kept aside as `<name>.corrupt` and the journal starts empty.
    public init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { store = []; return }
        let version = (try? JSONDecoder().decode(Header.self, from: data))?.version
        switch version {
        case 2:
            if let f = try? JSONDecoder().decode(FileFormat.self, from: data) { store = f.entries; return }
        case 1:
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let f = try? dec.decode(V1File.self, from: data) {
                let migrated = f.entries.map(Self.migrate)
                let fm = FileManager.default
                let bak = url.appendingPathExtension("v1")
                try? fm.removeItem(at: bak)
                try? fm.copyItem(at: url, to: bak)
                try? Self.write(migrated, to: url)
                store = migrated
                return
            }
        default: break
        }
        store = []
        let bak = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: url, to: bak)
    }

    private static func migrate(_ v1: V1Entry) -> Entry {
        let state: State
        switch v1.state {
        case "exported": state = .downloaded
        case "importVerified": state = .awaitingRemovalApproval
        default: state = State(rawValue: v1.state) ?? .planned
        }
        var e = Entry(original: v1.original, state: state, newID: v1.newID, updatedAt: v1.updatedAt ?? Date())
        if let m = v1.error { e.lastError = JobError(kind: "unknown", message: m) }
        return e
    }

    // MARK: Legacy API (v1 semantics)

    /// One entry per original. Recording the same state again is a no-op; a `removed` entry is final.
    /// `newID`/`error` keep their previous value when passed nil.
    public func record(original: MediaID, state: State, newID: MediaID? = nil, error: String? = nil,
                       now: Date = Date()) throws {
        try update(original, now: now) { e in
            e.state = state
            e.newID = newID ?? e.newID
            e.lastError = state == .failed || state == .skipped
                ? (error.map { JobError(kind: "unknown", message: $0) } ?? e.lastError) : nil
        }
    }

    // MARK: v2 API

    /// Applies `mutate` to the entry (creating a `planned` one if absent) and persists atomically when it changed.
    /// A `removed` entry is final. Returns the resulting entry.
    @discardableResult
    public func update(_ original: MediaID, now: Date = Date(),
                       _ mutate: @Sendable (inout Entry) -> Void) throws -> Entry {
        if let i = store.firstIndex(where: { $0.original == original }) {
            let old = store[i]
            if old.state == .removed { return old }
            var e = old
            mutate(&e)
            e.original = original
            if e == old { return old }
            e.updatedAt = now
            var next = store
            next[i] = e
            try Self.write(next, to: url)
            store = next
            return e
        }
        var e = Entry(original: original, updatedAt: now)
        mutate(&e)
        e.original = original
        e.updatedAt = now
        try Self.write(store + [e], to: url)
        store.append(e)
        return e
    }

    public func entries() -> [Entry] { store }

    /// Entries that are neither removed, skipped nor failed.
    public func pending() -> [Entry] { store.filter { !$0.state.isTerminal } }

    public func entry(for original: MediaID) -> Entry? { store.first { $0.original == original } }

    /// Originals may be removed only after the imported copy is verified (and the new copy is known).
    public func canRemoveOriginal(_ original: MediaID) -> Bool {
        guard let e = entry(for: original), e.newID != nil else { return false }
        return e.state == .awaitingRemovalApproval || e.state == .removing
    }

    /// Every id of an imported copy recorded for a job other than `original`.
    public func importedIDs(excludingJob original: MediaID? = nil) -> Set<MediaID> {
        Set(store.filter { $0.original != original }.compactMap(\.newID))
    }

    private static func write(_ entries: [Entry], to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(FileFormat(entries: entries))
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
