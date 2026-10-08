#if canImport(Photos)
import CoreGraphics
import CryptoKit
import Foundation
import PareCore
import Photos
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// PhotoKit adapter. Never used by automated tests.
public final class PhotoLibrary: MediaLibrary, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: PHAsset] = [:]

    public init() {}

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
        /// Returns true exactly once (for resuming continuations from repeated callbacks).
        func claim() -> Bool where T == Bool {
            lock.lock(); defer { lock.unlock() }
            if value { return false }
            value = true; return true
        }
    }

    // MARK: Authorization

    private static func map(_ s: PHAuthorizationStatus) -> LibraryAccess {
        switch s {
        case .authorized: .full
        case .limited: .limited
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    public func authorization() async -> LibraryAccess {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    public func requestAccess() async -> LibraryAccess {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    // MARK: Asset lookup

    private func cached(_ key: String) -> PHAsset? { lock.lock(); defer { lock.unlock() }; return cache[key] }
    private func store(_ key: String, _ a: PHAsset) { lock.lock(); cache[key] = a; lock.unlock() }
    private func replaceCache(_ c: [String: PHAsset]) { lock.lock(); cache = c; lock.unlock() }
    private func evict(_ keys: [String]) { lock.lock(); for k in keys { cache[k] = nil }; lock.unlock() }

    private func asset(_ id: MediaID) throws -> PHAsset {
        if let a = cached(id.raw) { return a }
        let r = PHAsset.fetchAssets(withLocalIdentifiers: [id.raw], options: nil)
        guard let a = r.firstObject else { throw LibraryError.notFound(id.raw) }
        store(id.raw, a)
        return a
    }

    private func originalVideoResource(_ asset: PHAsset) -> PHAssetResource? {
        let res = PHAssetResource.assetResources(for: asset)
        return res.first { $0.type == .video } ?? res.first { $0.type == .fullSizeVideo }
    }

    // MARK: Listing

    public func items() async throws -> [MediaItem] {
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = false
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let fetched = PHAsset.fetchAssets(with: opts)
        var items: [MediaItem] = []
        var newCache: [String: PHAsset] = [:]
        items.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in
            newCache[asset.localIdentifier] = asset
            items.append(Self.mediaItem(asset))
        }
        replaceCache(newCache)
        return items
    }

    private static func mediaItem(_ a: PHAsset) -> MediaItem {
        let resources = PHAssetResource.assetResources(for: a)
        let primary = resources.first {
            $0.type == .photo || $0.type == .video
        } ?? resources.first
        var size: Int64?
        if let primary, let n = primary.value(forKey: "fileSize") as? NSNumber { size = n.int64Value }
        var isLocal = true
        if let primary, let l = primary.value(forKey: "locallyAvailable") as? NSNumber {
            isLocal = l.boolValue
        }
        let edited = resources.contains {
            $0.type == .adjustmentData || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo
        }
        let kind: MediaKind
        if a.mediaType == .video { kind = .video }
        else if a.mediaSubtypes.contains(.photoScreenshot) { kind = .screenshot }
        else if a.mediaSubtypes.contains(.photoLive) { kind = .livePhoto }
        else { kind = .photo }
        let isVideo = a.mediaType == .video
        return MediaItem(
            id: MediaID(a.localIdentifier), kind: kind, creationDate: a.creationDate,
            pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight, byteSize: size,
            isFavorite: a.isFavorite, isEdited: edited, isLocal: isLocal,
            burstID: a.burstIdentifier, duration: isVideo ? a.duration : nil,
            videoCodec: nil, frameRate: nil, isHDR: false,
            isSlowMo: isVideo && a.mediaSubtypes.contains(.videoHighFrameRate))
    }

    // MARK: Thumbnails

    public func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage {
        let asset = try asset(id)
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = allowNetwork
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isSynchronous = false
        let done = Box(false)
        return try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit, options: opts
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard done.claim() else { return }
                if let image, let cg = Self.cgImage(from: image) { cont.resume(returning: cg) }
                else { cont.resume(throwing: LibraryError.thumbnailFailed) }
            }
        }
    }

    #if canImport(UIKit)
    private static func cgImage(from image: UIImage) -> CGImage? { image.cgImage }
    #elseif canImport(AppKit)
    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    #endif

    // MARK: Export / hash

    public func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool,
                            progress: @Sendable (Double) -> Void) async throws -> URL {
        let asset = try asset(id)
        guard let resource = originalVideoResource(asset) else {
            throw LibraryError.exportFailed("No original video resource")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = resource.originalFilename.isEmpty ? "video.mov" : resource.originalFilename
        let safe = id.raw.replacingOccurrences(of: "/", with: "_")
        let dest = dir.appendingPathComponent("\(safe)-\(name)")
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = allowNetwork
        try await withoutActuallyEscaping(progress) { escapableProgress in
            let report = UncheckedSendable(escapableProgress)
            opts.progressHandler = { report.value($0) }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: dest, options: opts) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        }
        progress(1)
        return dest
    }

    private struct UncheckedSendable<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

    public func exactHash(_ id: MediaID) async throws -> String? {
        guard let asset = try? asset(id) else { return nil }
        let res = PHAssetResource.assetResources(for: asset)
        guard let resource = res.first(where: { $0.type == .photo || $0.type == .video }) ?? res.first
        else { return nil }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = false
        let hasher = Box(SHA256())
        let ok: Bool = await withCheckedContinuation { cont in
            PHAssetResourceManager.default().requestData(
                for: resource, options: opts,
                dataReceivedHandler: { chunk in
                    var h = hasher.get(); h.update(data: chunk); hasher.set(h)
                },
                completionHandler: { error in cont.resume(returning: error == nil) })
        }
        guard ok else { return nil }
        return hasher.get().finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Import / delete

    public func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID {
        let source = try asset(original.id)
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(source, with: .album, options: nil)
        var regular: [PHAssetCollection] = []
        albums.enumerateObjects { c, _, _ in
            if c.assetCollectionSubtype == .albumRegular { regular.append(c) }
        }
        let created = Box<String?>(nil)
        let work = UncheckedSendable((source, regular))
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let (source, albums) = work.value
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = false
                req.addResource(with: .video, fileURL: file, options: opts)
                req.creationDate = source.creationDate
                req.location = source.location
                req.isFavorite = source.isFavorite
                req.isHidden = source.isHidden
                guard let placeholder = req.placeholderForCreatedAsset else { return }
                created.set(placeholder.localIdentifier)
                for album in albums {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            throw LibraryError.importFailed(error.localizedDescription)
        }
        guard let newID = created.get() else { throw LibraryError.importFailed("No identifier returned") }
        return MediaID(newID)
    }

    public func delete(_ ids: [MediaID]) async throws {
        let assets = try ids.map { try asset($0) }
        guard !assets.isEmpty else { return }
        let work = UncheckedSendable(assets)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(work.value as NSArray)
        }
        evict(ids.map(\.raw))
    }
}
#endif
