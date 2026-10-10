import Foundation

/// What a video file really contains, as opposed to the library's metadata. PhotoKit doesn't expose HDR or codec, so
/// these are probed from the file when it's on the device.
public struct VideoDetails: Sendable, Equatable, Codable {
    public var codec: String?
    public var frameRate: Double?
    public var isHDR: Bool
    public init(codec: String? = nil, frameRate: Double? = nil, isHDR: Bool = false) {
        self.codec = codec; self.frameRate = frameRate; self.isHDR = isHDR
    }
}

public extension MediaItem {
    func applying(_ d: VideoDetails) -> MediaItem {
        var i = self
        i.videoCodec = d.codec ?? videoCodec
        i.frameRate = d.frameRate ?? frameRate
        i.isHDR = isHDR || d.isHDR
        i.isSlowMo = isSlowMo || (d.frameRate ?? 0) > 60
        return i
    }
}

public extension PresetPolicy {
    /// Moves videos that are no longer eligible (after their details were probed) from `eligible` to `skipped`,
    /// keeping the order of what stays.
    static func reclassify(eligible: [MediaID], skipped: [(id: MediaID, reason: SkipReason)],
                           items: [MediaID: MediaItem]) -> (eligible: [MediaID], skipped: [(id: MediaID, reason: SkipReason)]) {
        var keep: [MediaID] = [], out = skipped
        for id in eligible {
            guard let item = items[id] else { keep.append(id); continue }
            if case .skipped(let reason) = eligibility(item) { out.append((id: id, reason: reason)) } else { keep.append(id) }
        }
        return (keep, out)
    }
}
