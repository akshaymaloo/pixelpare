import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PareCore
import UniformTypeIdentifiers
import os

/// Dev/fixture adapter that treats a directory as a media library.
public final class FolderLibrary: MediaLibrary {
    public let root: URL
    private static let imageExts: Set<String> = ["jpg", "jpeg", "heic", "png"]
    private static let videoExts: Set<String> = ["mov", "mp4", "m4v"]

    /// Test hooks that make the folder behave like PhotoKit does when things go wrong.
    public struct Faults: Sendable {
        /// `delete` throws `PHPhotosError.userCancelled` without deleting anything (the user declined the prompt).
        public var deleteUserCancels = false
        /// `delete` removes the first N ids, then throws `operationInterrupted`.
        public var deleteFailsAfter: Int?
        /// `importVideo` creates the copy and then throws this error (the response was lost).
        public var importErrorAfterCommit: NSError?
        /// Thrown by successive `exportVideo` calls (consumed front to back) before any file is written.
        public var exportErrors: [NSError] = []
        public init() {}
    }

    private let faultState = OSAllocatedUnfairLock(initialState: Faults())
    public var faults: Faults {
        get { faultState.withLock { $0 } }
        set { faultState.withLock { $0 = newValue } }
    }

    public init(root: URL) { self.root = root }

    public func authorization() async -> LibraryAccess { .full }
    public func requestAccess() async -> LibraryAccess { .full }

    // MARK: Listing

    private func candidateFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        func scan(_ dir: URL, depth: Int) {
            let entries = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for url in entries.sorted(by: { $0.path < $1.path }) {
                if url.lastPathComponent == ".trash" { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if depth == 0 { scan(url, depth: 1) }
                } else {
                    let ext = url.pathExtension.lowercased()
                    if Self.imageExts.contains(ext) || Self.videoExts.contains(ext) { out.append(url) }
                }
            }
        }
        scan(root, depth: 0)
        return out
    }

    private func relativePath(_ url: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(full.dropFirst(base.count + 1))
    }

    private func url(for id: MediaID) throws -> URL {
        guard !id.raw.split(separator: "/").contains("..") else { throw LibraryError.notFound(id.raw) }
        let u = root.appendingPathComponent(id.raw)
        guard FileManager.default.fileExists(atPath: u.path) else { throw LibraryError.notFound(id.raw) }
        return u
    }

    private func favorites() -> Set<String> {
        guard let text = try? String(contentsOf: root.appendingPathComponent("favorites.txt"), encoding: .utf8)
        else { return [] }
        return Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public func items() async throws -> [MediaItem] {
        let favs = favorites()
        var result: [MediaItem] = []
        for file in candidateFiles() {
            let rel = relativePath(file)
            let isFav = favs.contains(rel) || favs.contains(file.lastPathComponent)
            if Self.videoExts.contains(file.pathExtension.lowercased()) {
                result.append(await videoItem(file, rel: rel, favorite: isFav))
            } else if let item = imageItem(file, rel: rel, favorite: isFav) {
                result.append(item)
            }
        }
        return result
    }

    public func item(_ id: MediaID) async throws -> MediaItem? {
        guard let file = try? url(for: id) else { return nil }
        let favs = favorites()
        let rel = relativePath(file)
        let isFav = favs.contains(rel) || favs.contains(file.lastPathComponent)
        if Self.videoExts.contains(file.pathExtension.lowercased()) {
            var item = await videoItem(file, rel: rel, favorite: isFav)
            item = MediaItem(id: id, kind: item.kind, creationDate: item.creationDate, pixelWidth: item.pixelWidth,
                             pixelHeight: item.pixelHeight, byteSize: item.byteSize, isFavorite: item.isFavorite,
                             duration: item.duration, videoCodec: item.videoCodec, frameRate: item.frameRate,
                             modificationDate: item.modificationDate)
            return item
        }
        return imageItem(file, rel: rel, favorite: isFav)
    }

    public func videoDetails(_ id: MediaID) async -> VideoDetails? {
        guard let file = try? url(for: id) else { return nil }
        return await VideoDetailsProbe.load(AVURLAsset(url: file))
    }

    public func resourceSize(_ id: MediaID) async -> Int64? {
        guard let file = try? url(for: id) else { return nil }
        return fileInfo(file).size
    }

    private func fileInfo(_ url: URL) -> (size: Int64?, created: Date?, modified: Date?) {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        return (v?.fileSize.map(Int64.init), v?.creationDate, v?.contentModificationDate)
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private func imageItem(_ file: URL, rel: String, favorite: Bool) -> MediaItem? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifDate = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            .flatMap { Self.exifFormatter.date(from: $0) }
        let info = fileInfo(file)
        let isPNG = file.pathExtension.lowercased() == "png"
        let isScreenshot = file.lastPathComponent.lowercased().contains("screenshot")
            || (isPNG && exifDate == nil)
        return MediaItem(
            id: MediaID(rel), kind: isScreenshot ? .screenshot : .photo,
            creationDate: exifDate ?? info.created, pixelWidth: w, pixelHeight: h,
            byteSize: info.size, isFavorite: favorite, modificationDate: info.modified)
    }

    private func videoItem(_ file: URL, rel: String, favorite: Bool) async -> MediaItem {
        let info = fileInfo(file)
        let asset = AVURLAsset(url: file)
        var item = MediaItem(
            id: MediaID(rel), kind: .video, creationDate: info.created, byteSize: info.size,
            isFavorite: favorite, modificationDate: info.modified)
        if let d = try? await asset.load(.duration), d.isNumeric { item.duration = d.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize),
               let t = try? await track.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(t)
                item.pixelWidth = Int(abs(r.width).rounded())
                item.pixelHeight = Int(abs(r.height).rounded())
            }
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 { item.frameRate = Double(fps) }
            if let descs = try? await track.load(.formatDescriptions), let d = descs.first {
                item.videoCodec = Self.fourCC(CMFormatDescriptionGetMediaSubType(d))
            }
        }
        return item
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Operations

    public func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage {
        let file = try url(for: id)
        if Self.videoExts.contains(file.pathExtension.lowercased()) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            return try await gen.image(at: .zero).image
        }
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else {
            throw LibraryError.thumbnailFailed
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw LibraryError.thumbnailFailed
        }
        return img
    }

    public func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool,
                            progress: @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        if let injected = faultState.withLock({ $0.exportErrors.isEmpty ? nil : $0.exportErrors.removeFirst() }) {
            throw injected
        }
        let src = try url(for: id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        let partial = dest.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: dest)
        progress(0)
        try fm.copyItem(at: src, to: partial)
        try Task.checkCancellation()
        try fm.moveItem(at: partial, to: dest)
        progress(1)
        return dest
    }

    public func exactHash(_ id: MediaID) async throws -> String? {
        let file = try url(for: id)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID {
        let fm = FileManager.default
        let origRel = original.id.raw as NSString
        let dirPart = origRel.deletingLastPathComponent
        let targetDir = dirPart.isEmpty ? root : root.appendingPathComponent(dirPart)
        let ext = file.pathExtension.isEmpty ? "mov" : file.pathExtension
        let base = (origRel.lastPathComponent as NSString).deletingPathExtension
        var dest = targetDir.appendingPathComponent("\(base)-pare.\(ext)")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = targetDir.appendingPathComponent("\(base)-pare-\(n).\(ext)"); n += 1
        }
        try fm.copyItem(at: file, to: dest)
        if let date = original.creationDate {
            try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: dest.path)
        }
        if let lost = faultState.withLock({ $0.importErrorAfterCommit }) { throw lost }
        return MediaID(relativePath(dest))
    }

    public func findImportedCopy(fingerprint: ImportFingerprint, addedAfter: Date,
                                 excluding: Set<MediaID>) async throws -> MediaID? {
        for file in candidateFiles() where Self.videoExts.contains(file.pathExtension.lowercased()) {
            let rel = relativePath(file)
            if excluding.contains(MediaID(rel)) { continue }
            // The directory-added date can't be forged by `importVideo`, unlike creation/modification dates.
            if let added = try? file.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate,
               added < addedAfter.addingTimeInterval(-2) { continue }
            let item = await videoItem(file, rel: rel, favorite: false)
            if fingerprint.matches(item) { return item.id }
        }
        return nil
    }

    public func delete(_ ids: [MediaID]) async throws {
        let f = faults
        if f.deleteUserCancels { throw PhotosErrorCodes.error(PhotosErrorCodes.userCancelled) }
        let fm = FileManager.default
        let trash = root.appendingPathComponent(".trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        for (n, id) in ids.enumerated() {
            if let limit = f.deleteFailsAfter, n >= limit {
                throw PhotosErrorCodes.error(PhotosErrorCodes.operationInterrupted)
            }
            guard let src = try? url(for: id) else { continue }
            var dest = trash.appendingPathComponent(src.lastPathComponent)
            var k = 2
            while fm.fileExists(atPath: dest.path) {
                let base = src.deletingPathExtension().lastPathComponent
                dest = trash.appendingPathComponent("\(base)-\(k).\(src.pathExtension)"); k += 1
            }
            try fm.moveItem(at: src, to: dest)
        }
    }
}
