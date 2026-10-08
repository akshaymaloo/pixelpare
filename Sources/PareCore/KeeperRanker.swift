import Foundation

public enum KeeperRanker {
    static let sharpnessWeight = 0.5
    static let faceWeight = 0.25
    static let aestheticsWeight = 0.25
    /// Scores within one bucket are treated as ties and fall through to resolution/date.
    static let tieBucket = 0.02

    /// Order: favorite, then weighted quality score, then pixel count, then earliest date.
    /// Reasons are produced only for non-favorite, non-keeper members.
    public static func rank(
        _ ids: [MediaID],
        items: [MediaID: MediaItem],
        signals: [MediaID: ImageSignals],
        exactDuplicates: Bool = false
    ) -> (keeper: MediaID, reasons: [MediaID: [String]]) {
        precondition(!ids.isEmpty, "rank requires at least one id")
        let maxSharp = ids.compactMap { signals[$0]?.sharpness }.max() ?? 0

        func sharp(_ id: MediaID) -> Double {
            guard let s = signals[id]?.sharpness, maxSharp > 0 else { return 0.5 }
            return s / maxSharp
        }
        func face(_ id: MediaID) -> Double? { signals[id]?.faceQuality }
        func aesthetic(_ id: MediaID) -> Double? {
            signals[id]?.aesthetics.map { min(max(($0 + 1) / 2, 0), 1) }
        }
        func score(_ id: MediaID) -> Double {
            sharpnessWeight * sharp(id) + faceWeight * (face(id) ?? 0.5)
                + aestheticsWeight * (aesthetic(id) ?? 0.5)
        }
        func bucket(_ id: MediaID) -> Int { Int((score(id) / tieBucket).rounded()) }
        func fav(_ id: MediaID) -> Bool { items[id]?.isFavorite ?? false }
        func pixels(_ id: MediaID) -> Int { items[id]?.pixelCount ?? 0 }
        func date(_ id: MediaID) -> Date { items[id]?.creationDate ?? .distantFuture }

        let sorted = ids.sorted { a, b in
            if fav(a) != fav(b) { return fav(a) }
            if bucket(a) != bucket(b) { return bucket(a) > bucket(b) }
            if pixels(a) != pixels(b) { return pixels(a) > pixels(b) }
            if date(a) != date(b) { return date(a) < date(b) }
            return a.raw < b.raw
        }
        let keeper = sorted[0]

        var reasons: [MediaID: [String]] = [:]
        for id in ids where id != keeper && !fav(id) {
            if exactDuplicates { reasons[id] = ["Exact duplicate"]; continue }
            var r: [String] = []
            if sharp(id) < sharp(keeper) - 0.1 { r.append("Less sharp") }
            if let f = face(id), let kf = face(keeper), f < kf - 0.1 { r.append("Eyes/face less clear") }
            if let a = aesthetic(id), let ka = aesthetic(keeper), a < ka - 0.1 { r.append("Lower aesthetic score") }
            if pixels(id) < pixels(keeper) { r.append("Lower resolution") }
            if r.isEmpty { r.append("Very similar to the kept photo") }
            reasons[id] = r
        }
        return (keeper, reasons)
    }
}
