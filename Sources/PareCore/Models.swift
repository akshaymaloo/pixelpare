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

    public init(
        id: MediaID, kind: MediaKind = .photo, creationDate: Date? = nil,
        pixelWidth: Int = 0, pixelHeight: Int = 0, byteSize: Int64? = nil,
        isFavorite: Bool = false, isEdited: Bool = false, isLocal: Bool = true,
        burstID: String? = nil, duration: TimeInterval? = nil, videoCodec: String? = nil,
        frameRate: Double? = nil, isHDR: Bool = false, isSlowMo: Bool = false
    ) {
        self.id = id; self.kind = kind; self.creationDate = creationDate
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.byteSize = byteSize
        self.isFavorite = isFavorite; self.isEdited = isEdited; self.isLocal = isLocal
        self.burstID = burstID; self.duration = duration; self.videoCodec = videoCodec
        self.frameRate = frameRate; self.isHDR = isHDR; self.isSlowMo = isSlowMo
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
