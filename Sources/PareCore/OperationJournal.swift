import Foundation

public actor OperationJournal {
    public enum State: String, Codable, Sendable {
        case planned, exported, encoded, verified, imported, importVerified
        case awaitingRemovalApproval, removed, failed
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var original: MediaID
        public var state: State
        public var newID: MediaID?
        public var error: String?
        public var updatedAt: Date
    }

    private struct FileFormat: Codable { var version = 1; var entries: [Entry] }

    private let url: URL
    private var store: [Entry]

    /// Loads existing entries. An unreadable file is kept aside as `<name>.corrupt` and the journal starts empty.
    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let f = try? dec.decode(FileFormat.self, from: data) {
                store = f.entries
            } else {
                store = []
                let bak = url.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: bak)
                try? FileManager.default.moveItem(at: url, to: bak)
            }
        } else {
            store = []
        }
    }

    /// One entry per original. Recording the same state again is a no-op; a `removed` entry is final.
    /// `newID`/`error` keep their previous value when passed nil.
    public func record(original: MediaID, state: State, newID: MediaID? = nil, error: String? = nil,
                       now: Date = Date()) throws {
        if let i = store.firstIndex(where: { $0.original == original }) {
            var e = store[i]
            if e.state == .removed { return }
            let newNewID = newID ?? e.newID
            let newError = state == .failed ? (error ?? e.error) : nil
            if e.state == state && e.newID == newNewID && e.error == newError { return }
            e.state = state; e.newID = newNewID; e.error = newError; e.updatedAt = now
            store[i] = e
        } else {
            store.append(Entry(original: original, state: state, newID: newID, error: error, updatedAt: now))
        }
        try persist()
    }

    public func entries() -> [Entry] { store }

    /// Entries that are neither removed nor failed.
    public func pending() -> [Entry] { store.filter { $0.state != .removed && $0.state != .failed } }

    public func entry(for original: MediaID) -> Entry? { store.first { $0.original == original } }

    /// Originals may be removed only after the imported copy is verified (and the new copy is known).
    public func canRemoveOriginal(_ original: MediaID) -> Bool {
        guard let e = entry(for: original), e.newID != nil else { return false }
        return e.state == .importVerified || e.state == .awaitingRemovalApproval
    }

    private func persist() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try enc.encode(FileFormat(entries: store))
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
