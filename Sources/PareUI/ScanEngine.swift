import CoreGraphics
import Foundation
import PareCore
import PareLibrary
import PareVision

public struct ScanProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case listing, analyzing, grouping }
    public var phase: Phase
    public var completed: Int
    public var total: Int
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    public var message: String {
        switch phase {
        case .listing: "Reading your library…"
        case .analyzing: "Looking at photos… \(completed) of \(total)"
        case .grouping: "Finding similar photos…"
        }
    }
}

public struct ScanResult: Sendable {
    public var items: [MediaID: MediaItem]
    public var groups: [SimilarGroup]
    public var screenshotCandidates: [MediaID]
    public var blurryCandidates: [MediaID] = []
    public var eligibleVideos: [MediaID]
    public var skippedVideos: [(id: MediaID, reason: SkipReason)]
    /// Photos that could not be analysed (e.g. iCloud-only originals); they are never grouped.
    public var unanalyzedCount: Int
}

public actor ScanEngine {
    public static let thumbnailPixels = 512

    private let library: any MediaLibrary
    private let cacheURL: URL?
    private let concurrency: Int
    private let now: @Sendable () -> Date

    public init(library: any MediaLibrary, cacheURL: URL? = nil, concurrency: Int = 4,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library; self.cacheURL = cacheURL
        self.concurrency = max(1, concurrency); self.now = now
    }

    /// Cancel by cancelling the surrounding Task; partial analysis is still written to the cache.
    public func scan(progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        progress(ScanProgress(phase: .listing, completed: 0, total: 0))
        let all = try await library.items()
        try Task.checkCancellation()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var cache = SignalCache.load(from: cacheURL, revision: SignalExtractor.featurePrintRevision)
        let images = all.filter { $0.kind != .video }
        var signals: [MediaID: ImageSignals] = [:]
        var hashes: [MediaID: String] = [:]
        var todo: [MediaItem] = []
        for item in images {
            if let e = cache.entry(for: item), let s = e.signals {
                signals[item.id] = s
                if let h = e.exactHash { hashes[item.id] = h }
            } else { todo.append(item) }
        }

        let total = images.count
        var completed = total - todo.count
        progress(ScanProgress(phase: .analyzing, completed: completed, total: total))

        let lib = library
        var cancelled = false
        await withTaskGroup(of: Analysis.self) { group in
            var iterator = todo.makeIterator()
            func addNext(_ g: inout TaskGroup<Analysis>) {
                guard let item = iterator.next() else { return }
                g.addTask { await Self.analyze(item, library: lib) }
            }
            for _ in 0..<concurrency { addNext(&group) }
            while let result = await group.next() {
                if Task.isCancelled { cancelled = true; group.cancelAll(); continue }
                completed += 1
                cache.entries[result.id.raw] = SignalCache.Entry(
                    byteSize: byID[result.id]?.byteSize, modificationDate: byID[result.id]?.modificationDate, exactHash: result.hash, signals: result.signals)
                if let s = result.signals { signals[result.id] = s }
                if let h = result.hash { hashes[result.id] = h }
                progress(ScanProgress(phase: .analyzing, completed: completed, total: total))
                addNext(&group)
            }
        }
        cache.save(to: cacheURL)
        if cancelled || Task.isCancelled { throw CancellationError() }

        progress(ScanProgress(phase: .grouping, completed: total, total: total))
        let analyzable = images.filter { signals[$0.id] != nil || hashes[$0.id] != nil }
        let groups = Grouper.group(items: analyzable, signals: signals, exactHashes: hashes)

        let blurry = Self.blurryCandidates(images, signals: signals, excluding: Set(groups.flatMap(\.members)))
        let screenshots = ScreenshotRule.candidates(all, olderThan: 30, now: now())
        var eligible: [MediaID] = []
        var skipped: [(MediaID, SkipReason)] = []
        for v in all where v.kind == .video {
            switch PresetPolicy.eligibility(v) {
            case .eligible: eligible.append(v.id)
            case .skipped(let r): skipped.append((v.id, r))
            }
        }
        return ScanResult(items: byID, groups: groups, screenshotCandidates: screenshots,
                          blurryCandidates: blurry, eligibleVideos: eligible, skippedVideos: skipped.map { (id: $0.0, reason: $0.1) },
                          unanalyzedCount: images.count - signals.count)
    }

    /// Below this the Laplacian-variance score (0…1) says "very soft". Deliberately conservative; these are
    /// suggestions to look at, never pre-selected.
    public static let blurryThreshold = 0.08

    /// Soft, non-favorite photos that are not already part of a lookalike group, softest first.
    static func blurryCandidates(_ images: [MediaItem], signals: [MediaID: ImageSignals],
                                 excluding grouped: Set<MediaID>) -> [MediaID] {
        images
            .filter { $0.kind == .photo && !$0.isFavorite && !grouped.contains($0.id) }
            .compactMap { item in signals[item.id].map { (item.id, $0.sharpness) } }
            .filter { $0.1 < blurryThreshold }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.0)
    }

    private struct Analysis: Sendable {
        var id: MediaID
        var hash: String?
        var signals: ImageSignals?
    }

    private static func analyze(_ item: MediaItem, library: any MediaLibrary) async -> Analysis {
        if Task.isCancelled { return Analysis(id: item.id) }
        let hash = try? await library.exactHash(item.id)
        var signals: ImageSignals?
        if let image = try? await library.thumbnail(item.id, maxPixel: thumbnailPixels, allowNetwork: false) {
            signals = try? await SignalExtractor.signals(for: image, id: item.id)
        }
        return Analysis(id: item.id, hash: hash, signals: signals)
    }
}
