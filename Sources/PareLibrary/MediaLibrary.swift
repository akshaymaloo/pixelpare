import CoreGraphics
import Foundation
import PareCore

public enum LibraryAccess: String, Sendable, Equatable {
    case full, limited, denied, notDetermined
}

public enum LibraryError: Error, Sendable, Equatable {
    case notFound(String)
    case accessDenied
    case exportFailed(String)
    case importFailed(String)
    case thumbnailFailed
}

/// `PHPhotosError` domain and codes, spelled out so cross-platform code (and tests) can build and classify
/// PhotoKit errors without importing Photos.
public enum PhotosErrorCodes {
    public static let domain = "PHPhotosErrorDomain"
    public static let userCancelled = 3072
    public static let libraryVolumeOffline = 3114
    public static let relinquishingLibraryBundleToWriter = 3142
    public static let switchingSystemPhotoLibrary = 3143
    public static let networkAccessRequired = 3164
    public static let networkError = 3169
    public static let identifierNotFound = 3201
    public static let multipleIdentifiersFound = 3202
    public static let changeNotSupported = 3300
    public static let operationInterrupted = 3301
    public static let invalidResource = 3302
    public static let notEnoughSpace = 3305
    public static let accessRestricted = 3310
    public static let accessUserDenied = 3311

    public static func error(_ code: Int, _ message: String = "") -> NSError {
        NSError(domain: domain, code: code,
                userInfo: message.isEmpty ? nil : [NSLocalizedDescriptionKey: message])
    }
}

/// What identifies the compressed copy of an original, used to find a copy that was created but never journaled.
public struct ImportFingerprint: Sendable, Equatable {
    public var creationDate: Date?
    public var duration: TimeInterval
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Expected size of the copy; only used to rule out candidates whose known size is clearly different.
    public var byteSize: Int64?

    public static let durationTolerance: TimeInterval = 0.2

    public init(creationDate: Date?, duration: TimeInterval, pixelWidth: Int, pixelHeight: Int,
                byteSize: Int64? = nil) {
        self.creationDate = creationDate; self.duration = duration
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.byteSize = byteSize
    }

    /// Creation date equal within a second, duration within 0.2 s, and the same pixel size (orientation-insensitive,
    /// ±2 px for even rounding), and, when both sizes are known, within 10 % of the expected size. A fingerprint without a creation date never matches: it would be too weak.
    public func matches(_ item: MediaItem) -> Bool {
        guard item.kind == .video, let want = creationDate, let have = item.creationDate,
              abs(want.timeIntervalSince(have)) <= 1,
              let d = item.duration, abs(d - duration) <= Self.durationTolerance else { return false }
        let a = [pixelWidth, pixelHeight].sorted(), b = [item.pixelWidth, item.pixelHeight].sorted()
        guard abs(a[0] - b[0]) <= 2 && abs(a[1] - b[1]) <= 2 else { return false }
        if let want = byteSize, want > 0, let size = item.byteSize, size > 0,
           Double(size) < Double(want) * 0.9 || Double(size) > Double(want) * 1.1 { return false }
        return true
    }
}

public protocol MediaLibrary: Sendable {
    func authorization() async -> LibraryAccess
    func requestAccess() async -> LibraryAccess
    func items() async throws -> [MediaItem]
    /// The current state of one asset; nil when it no longer exists.
    func item(_ id: MediaID) async throws -> MediaItem?
    func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage
    /// Writes the original video into `dir` and returns its URL. The returned file is complete: implementations
    /// write to a `.partial` name and rename it, and honour task cancellation.
    func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool, progress: @Sendable (Double) -> Void) async throws -> URL
    /// SHA-256 (hex) of the original resource if available locally, else nil.
    func exactHash(_ id: MediaID) async throws -> String?
    /// Size in bytes of the asset's primary resource, nil if unknown or gone.
    func resourceSize(_ id: MediaID) async -> Int64?
    /// Codec, frame rate and HDR-ness of a video that is available on this device, nil when unknown or when reading
    /// it would need a download. Never uses the network.
    func videoDetails(_ id: MediaID) async -> VideoDetails?
    func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID
    /// A previously imported copy matching `fingerprint` that was added after `addedAfter`, ignoring `excluding`.
    func findImportedCopy(fingerprint: ImportFingerprint, addedAfter: Date,
                          excluding: Set<MediaID>) async throws -> MediaID?
    /// Deleting an id that no longer exists is not an error. A declined system prompt throws
    /// `PhotosErrorCodes.userCancelled`.
    func delete(_ ids: [MediaID]) async throws
    /// Creates a still photo from a Live Photo's photo resource (downloading it if needed), carrying over date,
    /// location, favorite, hidden and albums, and returns the new asset's id. The original is not touched.
    func convertLivePhotoToStill(_ id: MediaID) async throws -> MediaID
    /// A still created from `original` (same date and size, not a Live Photo) after `addedAfter`, ignoring `excluding`.
    func findStillCopy(of original: MediaItem, addedAfter: Date, excluding: Set<MediaID>) async throws -> MediaID?
}

public extension MediaLibrary {
    func videoDetails(_ id: MediaID) async -> VideoDetails? { nil }
    func item(_ id: MediaID) async throws -> MediaItem? { try await items().first { $0.id == id } }
    func resourceSize(_ id: MediaID) async -> Int64? { (try? await item(id))?.byteSize }
    func findImportedCopy(fingerprint: ImportFingerprint, addedAfter: Date,
                          excluding: Set<MediaID>) async throws -> MediaID? {
        try await items().first { !excluding.contains($0.id) && fingerprint.matches($0) }?.id
    }
}
