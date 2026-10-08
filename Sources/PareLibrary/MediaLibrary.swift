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

public protocol MediaLibrary: Sendable {
    func authorization() async -> LibraryAccess
    func requestAccess() async -> LibraryAccess
    func items() async throws -> [MediaItem]
    func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage
    func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool, progress: @Sendable (Double) -> Void) async throws -> URL
    /// SHA-256 (hex) of the original resource if available locally, else nil.
    func exactHash(_ id: MediaID) async throws -> String?
    func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID
    func delete(_ ids: [MediaID]) async throws
}
