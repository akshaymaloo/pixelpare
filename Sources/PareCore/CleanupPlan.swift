import Foundation

public struct CleanupPlan: Sendable, Equatable {
    public var removals: Set<MediaID>
    public var videoJobs: [MediaID: VideoPreset]
    /// Live Photos to turn into stills: a verified still copy is made, then the original goes to Recently Deleted.
    public var stillJobs: Set<MediaID>

    public init(removals: Set<MediaID> = [], videoJobs: [MediaID: VideoPreset] = [:], stillJobs: Set<MediaID> = []) {
        self.removals = removals; self.videoJobs = videoJobs; self.stillJobs = stillJobs.subtracting(removals)
    }

    /// Removals come only from approved groups (non-kept, non-favorite members) and the explicitly approved
    /// standalone items (`approvedScreenshots`: screenshots, blurry shots, burst leftovers, recordings, big items).
    /// Video jobs for videos that are also removed are dropped.
    public init(groups: [SimilarGroup], approvedScreenshots: Set<MediaID> = [],
                videoJobs: [MediaID: VideoPreset] = [:], stillJobs: Set<MediaID> = []) {
        var removals = approvedScreenshots
        for g in groups { removals.formUnion(g.approvedRemovals) }
        self.removals = removals
        self.videoJobs = videoJobs.filter { !removals.contains($0.key) }
        self.stillJobs = stillJobs.subtracting(removals)
    }

    public var isEmpty: Bool { removals.isEmpty && videoJobs.isEmpty && stillJobs.isEmpty }

    /// Each MediaID counts once; a video both removed and compressed counts only as a removal.
    /// Unknown sizes contribute 0 to the low bound and an estimate to the high bound.
    public func estimatedSavings(items: [MediaID: MediaItem]) -> ClosedRange<Int64> {
        var low: Int64 = 0, high: Int64 = 0
        for id in removals {
            guard let item = items[id] else { continue }
            if let size = item.byteSize { low += size; high += size }
            else { high += Self.guessSize(item) }
        }
        for (id, preset) in videoJobs where !removals.contains(id) {
            guard let item = items[id], PresetPolicy.eligibility(item).isEligible,
                  PresetPolicy.settings(for: item, preset: preset) != nil else { continue }
            let est = PresetPolicy.estimate(item, preset: preset)
            if let size = item.byteSize {
                low += max(0, size - est.high); high += max(0, size - est.low)
            } else {
                high += max(0, Self.guessSize(item) - est.low)
            }
        }
        for id in stillJobs where !removals.contains(id) {
            guard let item = items[id] else { continue }
            if let paired = item.pairedVideoBytes, paired > 0 {
                low += Int64(Double(paired) * 0.8); high += paired
            } else {
                high += Self.guessPairedVideo
            }
        }
        return low...max(low, high)
    }

    static let guessPairedVideo: Int64 = 3_000_000

    /// Rough original size when PhotoKit gives none.
    static func guessSize(_ item: MediaItem) -> Int64 {
        if item.kind == .video, let d = item.duration, d > 0 {
            let bpp = 0.15
            return Int64(bpp * Double(item.pixelCount) * (item.frameRate ?? 30) * d / 8)
        }
        return Int64(Double(item.pixelCount) * 0.4)
    }
}

public enum SafetyViolation: Error, Equatable, Sendable {
    case unknownItem(MediaID)
    case removalOfFavorite(MediaID)
    case removalWithoutApproval(MediaID)
    case removalOfKeptMember(MediaID)
    case groupWouldKeepNothing(UUID)
    case invalidKeepSet(UUID)
    case videoJobOnNonVideo(MediaID)
    case removalOfVideo(MediaID)
    case stillJobOnNonLivePhoto(MediaID)
}

public enum SafetyCheck {
    /// Enforces: no removal unless its group is approved (or it is a screenshot outside any group),
    /// favorites are never removed, every group keeps at least one member.
    /// `explicitlyApproved` are standalone (ungrouped) photos the user marked one by one, e.g. from the blurry tray;
    /// they get the same favorite protection as everything else.
    /// `approvedVideoRemovals` are videos the user picked one by one in the screen recordings or biggest-items tray;
    /// a video can only be removed through that explicit path.
    public static func validate(plan: CleanupPlan, groups: [SimilarGroup], items: [MediaID: MediaItem],
                                explicitlyApproved: Set<MediaID> = [],
                                approvedVideoRemovals: Set<MediaID> = []) throws {
        var groupOf: [MediaID: SimilarGroup] = [:]
        for g in groups { for m in g.members { groupOf[m] = g } }

        for id in plan.removals.sorted() {
            guard let item = items[id] else { throw SafetyViolation.unknownItem(id) }
            if item.isFavorite { throw SafetyViolation.removalOfFavorite(id) }
            // Videos leave only through an explicit per-item approval (recordings / biggest items), never in bulk.
            if item.kind == .video, !(approvedVideoRemovals.contains(id) && explicitlyApproved.contains(id)) {
                throw SafetyViolation.removalOfVideo(id)
            }
            if let g = groupOf[id] {
                if g.favorites.contains(id) { throw SafetyViolation.removalOfFavorite(id) }
                guard case .approved(let keep) = g.approval else { throw SafetyViolation.removalWithoutApproval(id) }
                if keep.contains(id) { throw SafetyViolation.removalOfKeptMember(id) }
            } else if item.kind != .screenshot, !explicitlyApproved.contains(id) {
                throw SafetyViolation.removalWithoutApproval(id)
            }
        }
        for g in groups {
            if case .approved(let keep) = g.approval {
                if keep.isEmpty || !keep.isSubset(of: Set(g.members)) { throw SafetyViolation.invalidKeepSet(g.id) }
            }
            if !g.members.isEmpty, Set(g.members).subtracting(plan.removals).isEmpty {
                throw SafetyViolation.groupWouldKeepNothing(g.id)
            }
        }
        for id in plan.stillJobs.sorted() {
            guard let item = items[id] else { throw SafetyViolation.unknownItem(id) }
            if item.kind != .livePhoto || item.isEdited { throw SafetyViolation.stillJobOnNonLivePhoto(id) }
        }
        for id in plan.videoJobs.keys.sorted() {
            guard let item = items[id] else { throw SafetyViolation.unknownItem(id) }
            if item.kind != .video { throw SafetyViolation.videoJobOnNonVideo(id) }
        }
    }
}
