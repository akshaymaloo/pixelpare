import Foundation
import PareCore

/// What identifies the still made from a Live Photo, used to find a copy that was created but never journaled.
/// The copy keeps the original's exact creation date, so matching is tight: two photos shot a moment apart never match.
public struct StillFingerprint: Sendable, Equatable {
    public var original: MediaID
    public var creationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var byteSize: Int64?

    public static let dateTolerance: TimeInterval = 0.05

    public init(of item: MediaItem) {
        original = item.id; creationDate = item.creationDate
        pixelWidth = item.pixelWidth; pixelHeight = item.pixelHeight; byteSize = item.byteSize
    }

    /// Plain photo, creation date equal within 50 ms, same pixel size (orientation-insensitive, ±2 px) and, when both
    /// sizes are known, within 10 %. Without a creation date nothing matches: too weak.
    public func matches(_ item: MediaItem) -> Bool {
        guard item.id != original, item.kind == .photo, let want = creationDate, let have = item.creationDate,
              abs(want.timeIntervalSince(have)) <= Self.dateTolerance else { return false }
        let a = [pixelWidth, pixelHeight].sorted(), b = [item.pixelWidth, item.pixelHeight].sorted()
        guard abs(a[0] - b[0]) <= 2 && abs(a[1] - b[1]) <= 2 else { return false }
        if let want = byteSize, want > 0, let size = item.byteSize, size > 0,
           Double(size) < Double(want) * 0.9 || Double(size) > Double(want) * 1.1 { return false }
        return true
    }
}

public extension MediaLibrary {
    func convertLivePhotoToStill(_ id: MediaID) async throws -> MediaID {
        throw LibraryError.importFailed("Making a still from a Live Photo isn't supported here")
    }

    func stillCopyCandidates(of original: MediaItem, addedAfter: Date, excluding: Set<MediaID>) async throws -> [MediaID] {
        let fingerprint = StillFingerprint(of: original)
        return try await items().filter { !excluding.contains($0.id) && fingerprint.matches($0) }.map(\.id)
    }

    func stillResourceDigest(_ id: MediaID) async throws -> String? { nil }
}
