import Foundation

public enum Strictness: Sendable { case conservative }

public enum Grouper {
    /// Near-identical: dHash Hamming distance at most this.
    public static let nearIdenticalMaxHamming = 4
    /// Similar: L2 distance between L2-normalised feature prints. Conservative; calibrated per
    /// featurePrintRevision later. Only same-revision prints are compared.
    public static let similarMaxDistance = 0.35
    /// Similar: capture-time window (seconds) relative to the group's representative.
    public static let similarTimeWindow: TimeInterval = 90

    /// Representative clustering (not union-find): a candidate joins a group only if it is within
    /// threshold of the group's representative (its earliest member). Each item is in at most one
    /// group; passes run exact → near-identical → similar. Videos are ignored. Groups of size 1 are dropped.
    public static func group(
        items: [MediaItem],
        signals: [MediaID: ImageSignals],
        exactHashes: [MediaID: String],
        strictness: Strictness = .conservative
    ) -> [SimilarGroup] {
        let ordered = items.filter { $0.kind != .video }.sorted {
            switch ($0.creationDate, $1.creationDate) {
            case let (a?, b?) where a != b: return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.id.raw < $1.id.raw
            }
        }
        let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var assigned = Set<MediaID>()
        var result: [(order: Int, group: SimilarGroup)] = []
        let position = Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        func emit(_ members: [MediaID], _ kind: GroupKind) {
            guard members.count > 1 else { return }
            assigned.formUnion(members)
            let ranked = KeeperRanker.rank(members, items: byID, signals: signals, exactDuplicates: kind == .exact)
            let favs = Set(members.filter { byID[$0]?.isFavorite ?? false })
            result.append((position[members[0]] ?? 0, SimilarGroup(
                members: members, suggestedKeeper: ranked.keeper, reasons: ranked.reasons,
                kind: kind, favorites: favs)))
        }

        // Pass 1: exact duplicates.
        var byHash: [String: [MediaID]] = [:]
        for item in ordered { if let h = exactHashes[item.id] { byHash[h, default: []].append(item.id) } }
        for item in ordered {
            guard !assigned.contains(item.id), let h = exactHashes[item.id], let ids = byHash[h] else { continue }
            emit(ids, .exact)
        }

        // Pass 2: near-identical, library-wide.
        for (i, rep) in ordered.enumerated() where !assigned.contains(rep.id) {
            guard let rs = signals[rep.id] else { continue }
            var members = [rep.id]
            for other in ordered[(i + 1)...] where !assigned.contains(other.id) {
                if let os = signals[other.id], rs.hammingDistance(to: os) <= nearIdenticalMaxHamming {
                    members.append(other.id)
                }
            }
            emit(members, .nearIdentical)
        }

        // Pass 3: similar within time window or burst.
        for (i, rep) in ordered.enumerated() where !assigned.contains(rep.id) {
            guard let rs = signals[rep.id] else { continue }
            var members = [rep.id]
            for other in ordered[(i + 1)...] where !assigned.contains(other.id) {
                // Sorted by date: once past the window (and not a burst-mate) nothing later can match.
                if let dr = rep.creationDate, let doth = other.creationDate,
                   doth.timeIntervalSince(dr) > similarTimeWindow,
                   rep.burstID == nil || rep.burstID != other.burstID { break }
                guard let os = signals[other.id], isNear(rep, other),
                      let d = rs.featureDistance(to: os), d <= similarMaxDistance else { continue }
                members.append(other.id)
            }
            emit(members, .similar)
        }

        return result.sorted { $0.order < $1.order }.map(\.group)
    }

    static func isNear(_ a: MediaItem, _ b: MediaItem) -> Bool {
        if let x = a.burstID, x == b.burstID { return true }
        guard let da = a.creationDate, let db = b.creationDate else { return false }
        return abs(da.timeIntervalSince(db)) <= similarTimeWindow
    }
}
