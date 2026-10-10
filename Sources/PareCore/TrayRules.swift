import Foundation

/// A burst whose pick is known, with the frames that can be offered for removal.
public struct BurstGroup: Identifiable, Sendable, Equatable {
    public var id: String { burstID }
    public var burstID: String
    /// The user/auto picks, which are never offered.
    public var picks: [MediaID]
    /// Non-picked, non-favorite frames.
    public var leftovers: [MediaID]
}

public enum ScreenRecordingRule {
    /// Screen recordings older than `days`, biggest first (unknown sizes last). Favorites and undated items never qualify.
    public static func candidates(_ items: [MediaItem], olderThan days: Int = 30, now: Date) -> [MediaID] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items
            .filter { $0.kind == .video && $0.isScreenRecording && !$0.isFavorite
                && ($0.creationDate.map { $0 <= cutoff } ?? false) }
            .sorted { (-($0.byteSize ?? -1), $0.id) < (-($1.byteSize ?? -1), $1.id) }
            .map(\.id)
    }
}

public enum BiggestRule {
    public static let defaultLimit = 50
    public static let defaultMinimumBytes: Int64 = 10_000_000

    /// The largest items of any kind (known sizes only, at least `minimumBytes`), biggest first. Burst leftovers
    /// have their own tray. Favorites are listed (they can still be pressed) but can't be marked for removal.
    public static func candidates(_ items: [MediaItem], limit: Int = defaultLimit,
                                  minimumBytes: Int64 = defaultMinimumBytes) -> [MediaID] {
        items
            .filter { $0.burstPick != false && ($0.byteSize ?? 0) >= minimumBytes }
            .sorted { (-($0.byteSize ?? 0), $0.id) < (-($1.byteSize ?? 0), $1.id) }
            .prefix(limit).map(\.id)
    }
}

public enum BurstRule {
    /// Bursts that have a pick and at least one removable leftover, most reclaimable bytes first.
    /// A burst without a user/auto pick is never offered: there would be nothing to keep.
    public static func groups(_ items: [MediaItem]) -> [BurstGroup] {
        var frames: [String: [MediaItem]] = [:]
        for item in items where item.kind != .video {
            if let b = item.burstID, item.burstPick != nil { frames[b, default: []].append(item) }
        }
        func bytes(_ g: BurstGroup, _ byID: [MediaID: MediaItem]) -> Int64 {
            g.leftovers.reduce(0) { $0 + (byID[$1]?.byteSize ?? 0) }
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return frames.compactMap { burst, members -> BurstGroup? in
            let picks = members.filter { $0.burstPick == true }.map(\.id).sorted()
            let leftovers = members.filter { $0.burstPick == false && !$0.isFavorite }.map(\.id).sorted()
            guard !picks.isEmpty, !leftovers.isEmpty else { return nil }
            return BurstGroup(burstID: burst, picks: picks, leftovers: leftovers)
        }
        .sorted { (-bytes($0, byID), $0.burstID) < (-bytes($1, byID), $1.burstID) }
    }
}

public enum LivePhotoRule {
    /// Unedited Live Photos whose paired video size is known, biggest paired video first. Favorites are included
    /// (nothing but the motion is lost) but the UI never pre-selects anything.
    public static func candidates(_ items: [MediaItem]) -> [MediaID] {
        items
            .filter { $0.kind == .livePhoto && !$0.isEdited && ($0.pairedVideoBytes ?? 0) > 0 }
            .sorted { (-($0.pairedVideoBytes ?? 0), $0.id) < (-($1.pairedVideoBytes ?? 0), $1.id) }
            .map(\.id)
    }
}
