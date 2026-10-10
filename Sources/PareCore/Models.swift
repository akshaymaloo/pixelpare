import Foundation

public struct MediaID: Hashable, Codable, Sendable, Comparable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public static func < (a: MediaID, b: MediaID) -> Bool { a.raw < b.raw }
}

public enum MediaKind: String, Codable, Sendable { case photo, video, screenshot, livePhoto }

public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public let id: MediaID
    public var kind: MediaKind
    public var creationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// nil = unknown (iCloud-only asset without a public size).
    public var byteSize: Int64?
    public var isFavorite: Bool
    public var isEdited: Bool
    public var isLocal: Bool
    public var burstID: String?
    public var duration: TimeInterval?
    public var videoCodec: String?
    public var frameRate: Double?
    public var isHDR: Bool
    public var isSlowMo: Bool
    /// Last modification of the asset; changes when the user edits the original.
    public var modificationDate: Date?
    /// A screen recording (PhotoKit `.videoScreenRecording`).
    public var isScreenRecording: Bool
    /// nil = not part of a burst; true = the burst's user/auto pick; false = a frame the user never picked.
    public var burstPick: Bool?
    /// Size of a Live Photo's paired video; only set when it can safely be dropped (nil = unknown or not offered).
    public var pairedVideoBytes: Int64?

    public init(
        id: MediaID, kind: MediaKind = .photo, creationDate: Date? = nil,
        pixelWidth: Int = 0, pixelHeight: Int = 0, byteSize: Int64? = nil,
        isFavorite: Bool = false, isEdited: Bool = false, isLocal: Bool = true,
        burstID: String? = nil, duration: TimeInterval? = nil, videoCodec: String? = nil,
        frameRate: Double? = nil, isHDR: Bool = false, isSlowMo: Bool = false,
        modificationDate: Date? = nil, isScreenRecording: Bool = false, burstPick: Bool? = nil,
        pairedVideoBytes: Int64? = nil
    ) {
        self.id = id; self.kind = kind; self.creationDate = creationDate
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.byteSize = byteSize
        self.isFavorite = isFavorite; self.isEdited = isEdited; self.isLocal = isLocal
        self.burstID = burstID; self.duration = duration; self.videoCodec = videoCodec
        self.frameRate = frameRate; self.isHDR = isHDR; self.isSlowMo = isSlowMo
        self.modificationDate = modificationDate
        self.isScreenRecording = isScreenRecording; self.burstPick = burstPick; self.pairedVideoBytes = pairedVideoBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, creationDate, pixelWidth, pixelHeight, byteSize, isFavorite, isEdited, isLocal, burstID
        case duration, videoCodec, frameRate, isHDR, isSlowMo, modificationDate
        case isScreenRecording, burstPick, pairedVideoBytes
    }

    /// Fields added after v1 decode as absent-is-default so older caches keep loading.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(MediaID.self, forKey: .id)
        kind = try c.decode(MediaKind.self, forKey: .kind)
        creationDate = try c.decodeIfPresent(Date.self, forKey: .creationDate)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        byteSize = try c.decodeIfPresent(Int64.self, forKey: .byteSize)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        isEdited = try c.decode(Bool.self, forKey: .isEdited)
        isLocal = try c.decode(Bool.self, forKey: .isLocal)
        burstID = try c.decodeIfPresent(String.self, forKey: .burstID)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec)
        frameRate = try c.decodeIfPresent(Double.self, forKey: .frameRate)
        isHDR = try c.decode(Bool.self, forKey: .isHDR)
        isSlowMo = try c.decode(Bool.self, forKey: .isSlowMo)
        modificationDate = try c.decodeIfPresent(Date.self, forKey: .modificationDate)
        isScreenRecording = try c.decodeIfPresent(Bool.self, forKey: .isScreenRecording) ?? false
        burstPick = try c.decodeIfPresent(Bool.self, forKey: .burstPick)
        pairedVideoBytes = try c.decodeIfPresent(Int64.self, forKey: .pairedVideoBytes)
    }

    public var pixelCount: Int { pixelWidth * pixelHeight }
}

public enum GroupKind: String, Codable, Sendable { case exact, nearIdentical, similar }

public enum Approval: Codable, Sendable, Equatable {
    case suggested
    case approved(keep: Set<MediaID>)
    case skipped
}

public struct SimilarGroup: Identifiable, Codable, Sendable {
    public let id: UUID
    public var members: [MediaID]
    public var suggestedKeeper: MediaID
    /// Why each non-keeper is suggested for removal.
    public var reasons: [MediaID: [String]]
    public var kind: GroupKind
    /// Members that were favorites when the group was formed; these are never removable.
    public var favorites: Set<MediaID>
    public var approval: Approval

    public init(
        id: UUID = UUID(), members: [MediaID], suggestedKeeper: MediaID,
        reasons: [MediaID: [String]] = [:], kind: GroupKind,
        favorites: Set<MediaID> = [], approval: Approval = .suggested
    ) {
        self.id = id; self.members = members; self.suggestedKeeper = suggestedKeeper
        self.reasons = reasons; self.kind = kind; self.favorites = favorites; self.approval = approval
    }

    /// Members kept by default: the suggested keeper plus all favorites.
    public var defaultKeep: Set<MediaID> { favorites.union([suggestedKeeper]) }

    /// Members that would be removed if the group is approved (empty unless approved).
    public var approvedRemovals: Set<MediaID> {
        guard case .approved(let keep) = approval else { return [] }
        return Set(members).subtracting(keep).subtracting(favorites)
    }

    /// Members that the current suggestion would remove, regardless of approval state.
    public var suggestedRemovals: Set<MediaID> {
        Set(members).subtracting(defaultKeep)
    }
}
