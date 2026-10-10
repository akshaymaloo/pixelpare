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

    /// Lookups by id must also see non-representative burst frames, which PhotoKit hides by default.
    private static var lookupOptions: PHFetchOptions {
        let o = PHFetchOptions()
        o.includeAllBurstAssets = true
        return o
    }

    private func asset(_ id: MediaID) throws -> PHAsset {
        if let a = cached(id.raw) { return a }
        let r = PHAsset.fetchAssets(withLocalIdentifiers: [id.raw], options: Self.lookupOptions)
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
        // Without this PhotoKit hides every non-representative burst frame.
        opts.includeAllBurstAssets = true
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
        var burstPick: Bool?
        if a.burstIdentifier != nil {
            burstPick = !a.burstSelectionTypes.isDisjoint(with: [.userPick, .autoPick])
        }
        // Loop / bounce / long-exposure Live Photos aren't offered: turning them into stills loses the effect.
        var pairedBytes: Int64?
        if kind == .livePhoto, !edited, a.playbackStyle == .livePhoto,
           let n = resources.first(where: { $0.type == .pairedVideo })?.value(forKey: "fileSize") as? NSNumber {
            pairedBytes = n.int64Value
        }
        return MediaItem(
            id: MediaID(a.localIdentifier), kind: kind, creationDate: a.creationDate,
            pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight, byteSize: size,
            isFavorite: a.isFavorite, isEdited: edited, isLocal: isLocal,
            burstID: a.burstIdentifier, duration: isVideo ? a.duration : nil,
            videoCodec: nil, frameRate: nil, isHDR: false,
            isSlowMo: isVideo && a.mediaSubtypes.contains(.videoHighFrameRate),
            modificationDate: a.modificationDate,
            isScreenRecording: isVideo && a.mediaSubtypes.contains(.videoScreenRecording),
            burstPick: burstPick, pairedVideoBytes: pairedBytes)
    }

    public func item(_ id: MediaID) async throws -> MediaItem? {
        // Always a fresh fetch: a cached PHAsset can outlive the asset it points at.
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id.raw], options: Self.lookupOptions).firstObject else {
            evict([id.raw])
            return nil
        }
        store(id.raw, a)
        return Self.mediaItem(a)
    }

    public func resourceSize(_ id: MediaID) async -> Int64? {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [id.raw], options: Self.lookupOptions).firstObject,
              let res = originalVideoResource(a) ?? PHAssetResource.assetResources(for: a).first,
              let n = res.value(forKey: "fileSize") as? NSNumber else { return nil }
        return n.int64Value
    }

    public func findImportedCopy(fingerprint: ImportFingerprint, addedAfter: Date,
                                 excluding: Set<MediaID>) async throws -> MediaID? {
        guard let created = fingerprint.creationDate else { return nil }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.video.rawValue,
            created.addingTimeInterval(-1) as NSDate, created.addingTimeInterval(1) as NSDate)
        var found: MediaID?
        PHAsset.fetchAssets(with: opts).enumerateObjects { a, _, stop in
            let id = MediaID(a.localIdentifier)
            guard !excluding.contains(id), fingerprint.matches(Self.mediaItem(a)) else { return }
            // PhotoKit has no public "date added"; only exclude copies that were clearly modified long before the
            // import started.
            if let m = a.modificationDate, m < addedAfter.addingTimeInterval(-3600) { return }
            found = id; stop.pointee = true
        }
        return found
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
        try Task.checkCancellation()
        let asset = try asset(id)
        guard let resource = originalVideoResource(asset) else {
            throw LibraryError.exportFailed("No original video resource")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = resource.originalFilename.isEmpty ? "video.mov" : resource.originalFilename
        let safe = id.raw.replacingOccurrences(of: "/", with: "_")
        let dest = dir.appendingPathComponent("\(safe)-\(name)")
        let partial = dest.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let transfer = DataTransfer(handle: try FileHandle(forWritingTo: partial))

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = allowNetwork
        do {
            try await withoutActuallyEscaping(progress) { escapableProgress in
                let report = UncheckedSendable(escapableProgress)
                opts.progressHandler = { report.value($0) }
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        let manager = PHAssetResourceManager.default()
                        let request = manager.requestData(
                            for: resource, options: opts,
                            dataReceivedHandler: { transfer.write($0) },
                            completionHandler: { cont.resume(with: transfer.finish($0)) })
                        transfer.attach(request, manager)
                    }
                } onCancel: {
                    transfer.cancel()
                }
            }
            let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw LibraryError.exportFailed("The exported file is empty") }
            try fm.moveItem(at: partial, to: dest)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        progress(1)
        return dest
    }

    /// Streams `requestData` chunks into a file; a failed write (e.g. disk full) cancels the request.
    private final class DataTransfer: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: FileHandle?
        private var writeError: Error?
        private var request: PHAssetResourceDataRequestID?
        private var manager: PHAssetResourceManager?
        private var cancelled = false

        init(handle: FileHandle) { self.handle = handle }

        func write(_ data: Data) {
            lock.lock()
            guard writeError == nil, let handle else { lock.unlock(); return }
            var failed = false
            do { try handle.write(contentsOf: data) } catch { writeError = error; failed = true }
            lock.unlock()
            if failed { cancel() }
        }

        func attach(_ request: PHAssetResourceDataRequestID, _ manager: PHAssetResourceManager) {
            lock.lock()
            self.request = request; self.manager = manager
            let already = cancelled
            lock.unlock()
            if already { manager.cancelDataRequest(request) }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let (r, m) = (request, manager)
            lock.unlock()
            if let r, let m { m.cancelDataRequest(r) }
        }

        func finish(_ error: Error?) -> Result<Void, Error> {
            lock.lock(); defer { lock.unlock() }
            try? handle?.close(); handle = nil
            if let writeError { return .failure(writeError) }
            if cancelled { return .failure(CancellationError()) }
            if let error { return .failure(error) }
            return .success(())
        }
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

    private func regularAlbums(containing source: PHAsset) -> [PHAssetCollection] {
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(source, with: .album, options: nil)
        var regular: [PHAssetCollection] = []
        albums.enumerateObjects { c, _, _ in
            if c.assetCollectionSubtype == .albumRegular { regular.append(c) }
        }
        return regular
    }

    /// Creates a new asset from `resource` and carries over date, location, favorite, hidden and album membership.
    private func createAsset(_ resource: PHAssetResourceType, file: URL, preserving source: PHAsset,
                             filename: String? = nil, uti: String? = nil) async throws -> MediaID {
        let created = Box<String?>(nil)
        let work = UncheckedSendable((source, regularAlbums(containing: source)))
        try await PHPhotoLibrary.shared().performChanges {
            let (source, albums) = work.value
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.shouldMoveFile = false
            if let filename { opts.originalFilename = filename }
            if let uti { opts.uniformTypeIdentifier = uti }
            req.addResource(with: resource, fileURL: file, options: opts)
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
        guard let newID = created.get() else { throw LibraryError.importFailed("No identifier returned") }
        return MediaID(newID)
    }

    public func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID {
        try await createAsset(.video, file: file, preserving: try asset(original.id))
    }

    // MARK: Live Photo → still

    public func convertLivePhotoToStill(_ id: MediaID) async throws -> MediaID {
        try Task.checkCancellation()
        let source = try asset(id)
        let resources = PHAssetResource.assetResources(for: source)
        // Edited Live Photos are never converted: the new asset would bake in or lose the edit.
        guard source.mediaSubtypes.contains(.photoLive),
              !resources.contains(where: { $0.type == .adjustmentData || $0.type == .fullSizePhoto }),
              let photo = resources.first(where: { $0.type == .photo }) else {
            throw LibraryError.exportFailed("No unedited photo resource to copy")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelpare-still-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = photo.originalFilename.isEmpty ? "photo.heic" : photo.originalFilename
        let file = dir.appendingPathComponent(name)
        try await write(photo, to: file, allowNetwork: true)
        try Task.checkCancellation()
        return try await createAsset(.photo, file: file, preserving: source, filename: name,
                                     uti: photo.uniformTypeIdentifier)
    }

    /// Writes one resource to `dest` (via a `.partial` file), downloading from iCloud if needed.
    private func write(_ resource: PHAssetResource, to dest: URL, allowNetwork: Bool) async throws {
        let fm = FileManager.default
        let partial = dest.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let transfer = DataTransfer(handle: try FileHandle(forWritingTo: partial))
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = allowNetwork
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let manager = PHAssetResourceManager.default()
                    let request = manager.requestData(
                        for: resource, options: opts,
                        dataReceivedHandler: { transfer.write($0) },
                        completionHandler: { cont.resume(with: transfer.finish($0)) })
                    transfer.attach(request, manager)
                }
            } onCancel: { transfer.cancel() }
            let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw LibraryError.exportFailed("The exported file is empty") }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: partial, to: dest)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    public func findStillCopy(of original: MediaItem, addedAfter: Date,
                              excluding: Set<MediaID>) async throws -> MediaID? {
        guard let created = original.creationDate else { return nil }
        let fingerprint = StillFingerprint(of: original)
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true
        opts.includeAllBurstAssets = true
        opts.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.image.rawValue,
            created.addingTimeInterval(-1) as NSDate, created.addingTimeInterval(1) as NSDate)
        var found: MediaID?
        PHAsset.fetchAssets(with: opts).enumerateObjects { a, _, stop in
            let id = MediaID(a.localIdentifier)
            guard !excluding.contains(id), fingerprint.matches(Self.mediaItem(a)) else { return }
            if let m = a.modificationDate, m < addedAfter.addingTimeInterval(-3600) { return }
            found = id; stop.pointee = true
        }
        return found
    }

    public func delete(_ ids: [MediaID]) async throws {
        // Already-missing ids are skipped. A declined system prompt surfaces as PHPhotosError.userCancelled.
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.raw), options: Self.lookupOptions)
            .enumerateObjects { a, _, _ in assets.append(a) }
        guard !assets.isEmpty else { evict(ids.map(\.raw)); return }
        let work = UncheckedSendable(assets)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(work.value as NSArray)
        }
        evict(ids.map(\.raw))
    }
}
#endif
