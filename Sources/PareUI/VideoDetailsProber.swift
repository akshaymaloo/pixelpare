import Foundation
import PareCore
import PareLibrary

/// Probes locally available videos for codec, frame rate and HDR after a scan, so HDR videos leave the eligible
/// list before anything is downloaded. Results are cached by id, size and modification date.
struct VideoDetailsCache: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var byteSize: Int64?
        var modificationDate: Date?
        var details: VideoDetails
    }
    var entries: [String: Entry] = [:]

    static func load(from url: URL?) -> VideoDetailsCache {
        guard let url, let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(VideoDetailsCache.self, from: data) else { return VideoDetailsCache() }
        return c
    }

    func save(to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func details(for item: MediaItem) -> VideoDetails? {
        guard let e = entries[item.id.raw], e.byteSize == item.byteSize,
              e.modificationDate == item.modificationDate else { return nil }
        return e.details
    }
}

enum VideoDetailsProber {
    /// Calls `found` on the main actor as details arrive. Videos that are only in iCloud are left alone; they are
    /// checked after download by the pipeline.
    static func run(items: [MediaItem], library: any MediaLibrary, cacheURL: URL?, concurrency: Int = 3,
                    found: @MainActor @Sendable @escaping (MediaID, VideoDetails) -> Void) async {
        var cache = VideoDetailsCache.load(from: cacheURL)
        var todo: [MediaItem] = []
        for item in items where item.kind == .video && item.isLocal {
            if let d = cache.details(for: item) { await found(item.id, d) } else { todo.append(item) }
        }
        var fresh: [(MediaItem, VideoDetails)] = []
        await withTaskGroup(of: (MediaItem, VideoDetails)?.self) { group in
            var next = 0
            func add() {
                guard next < todo.count else { return }
                let item = todo[next]; next += 1
                group.addTask { await library.videoDetails(item.id).map { (item, $0) } }
            }
            for _ in 0..<concurrency { add() }
            while let r = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                if let (item, d) = r { fresh.append((item, d)); await found(item.id, d) }
                add()
            }
        }
        guard !fresh.isEmpty, !Task.isCancelled else { return }
        for (item, d) in fresh {
            cache.entries[item.id.raw] = .init(byteSize: item.byteSize, modificationDate: item.modificationDate, details: d)
        }
        cache.save(to: cacheURL)
    }
}
