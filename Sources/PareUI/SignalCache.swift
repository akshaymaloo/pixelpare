import Foundation
import PareCore

/// Simple JSON cache of per-item scan results, keyed by MediaID.
/// Entries are dropped when the feature-print revision or the item's byte size changes.
struct SignalCache: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var byteSize: Int64?
        var modificationDate: Date?
        var exactHash: String?
        var signals: ImageSignals?
    }

    var revision: Int
    var entries: [String: Entry] = [:]

    static func load(from url: URL?, revision: Int) -> SignalCache {
        guard let url, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(SignalCache.self, from: data),
              cache.revision == revision else { return SignalCache(revision: revision) }
        return cache
    }

    func save(to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func entry(for item: MediaItem) -> Entry? {
        guard let e = entries[item.id.raw], e.byteSize == item.byteSize, e.modificationDate == item.modificationDate else { return nil }
        return e
    }
}
