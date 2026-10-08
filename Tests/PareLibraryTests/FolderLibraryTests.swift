import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PareCore
import Testing
import UniformTypeIdentifiers
@testable import PareLibrary

private func makeCGImage(width: Int = 64, height: Int = 48, gray: CGFloat = 0.5) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(gray: gray, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func writeImage(_ url: URL, type: UTType, exifDate: String? = nil) throws {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [:]
    if let exifDate { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate] }
    CGImageDestinationAddImage(dest, makeCGImage(), props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

private func writeVideo(_ url: URL, seconds: Int = 1, fps: Int = 10) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96,
        ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for i in 0..<(seconds * fps) {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 128, 96, kCVPixelFormatType_32BGRA, nil, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        memset(CVPixelBufferGetBaseAddress(buf), 0x80, CVPixelBufferGetDataSize(buf))
        CVPixelBufferUnlockBaseAddress(buf, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? LibraryError.exportFailed("writer") }
}

private func makeRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderLibraryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct FolderLibraryTests {
    @Test func listsAndClassifiesItems() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(root.appendingPathComponent("a.jpg"), type: .jpeg, exifDate: "2024:05:06 07:08:09")
        try writeImage(root.appendingPathComponent("Screenshot 1.jpg"), type: .jpeg)
        try writeImage(root.appendingPathComponent("plain.png"), type: .png)
        let sub = root.appendingPathComponent("trip")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeImage(sub.appendingPathComponent("b.jpeg"), type: .jpeg, exifDate: "2024:05:06 07:08:10")
        let trash = root.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try writeImage(trash.appendingPathComponent("gone.jpg"), type: .jpeg)
        try await writeVideo(root.appendingPathComponent("clip.mov"))
        try "a.jpg\n".write(to: root.appendingPathComponent("favorites.txt"), atomically: true, encoding: .utf8)

        let lib = FolderLibrary(root: root)
        let items = try await lib.items()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id.raw, $0) })
        #expect(Set(byID.keys) == ["a.jpg", "Screenshot 1.jpg", "plain.png", "trip/b.jpeg", "clip.mov"])

        let a = try #require(byID["a.jpg"])
        #expect(a.kind == .photo && a.isFavorite)
        #expect(a.pixelWidth == 64 && a.pixelHeight == 48)
        #expect(a.byteSize ?? 0 > 0)
        var comps = DateComponents(year: 2024, month: 5, day: 6, hour: 7, minute: 8, second: 9)
        comps.timeZone = TimeZone.current
        #expect(a.creationDate == Calendar.current.date(from: comps))
        #expect(byID["Screenshot 1.jpg"]?.kind == .screenshot)
        #expect(byID["plain.png"]?.kind == .screenshot)
        #expect(byID["trip/b.jpeg"]?.isFavorite == false)

        let v = try #require(byID["clip.mov"])
        #expect(v.kind == .video)
        #expect(v.pixelWidth == 128 && v.pixelHeight == 96)
        #expect(abs((v.duration ?? 0) - 1) < 0.2)
        #expect(v.videoCodec == "avc1")
        #expect(abs((v.frameRate ?? 0) - 10) < 1)
    }

    @Test func thumbnailsAndHash() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writeImage(root.appendingPathComponent("a.jpg"), type: .jpeg)
        try await writeVideo(root.appendingPathComponent("clip.mov"))
        let lib = FolderLibrary(root: root)
        let thumb = try await lib.thumbnail(MediaID("a.jpg"), maxPixel: 32, allowNetwork: false)
        #expect(max(thumb.width, thumb.height) == 32)
        let vthumb = try await lib.thumbnail(MediaID("clip.mov"), maxPixel: 64, allowNetwork: false)
        #expect(vthumb.width <= 64)
        let h1 = try await lib.exactHash(MediaID("a.jpg"))
        let h2 = try await lib.exactHash(MediaID("a.jpg"))
        #expect(h1 != nil && h1 == h2 && h1?.count == 64)
        let hv = try await lib.exactHash(MediaID("clip.mov"))
        #expect(hv != h1)
    }

    @Test func exportImportDelete() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try await writeVideo(root.appendingPathComponent("clip.mov"))
        let lib = FolderLibrary(root: root)
        let original = try #require(try await lib.items().first)

        let exportDir = root.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: exportDir) }
        let progress = Progress()
        let exported = try await lib.exportVideo(original.id, to: exportDir, allowNetwork: false) { p in
            progress.completedUnitCount = Int64(p * 100)
        }
        #expect(FileManager.default.fileExists(atPath: exported.path))
        #expect(progress.completedUnitCount == 100)

        var orig = original
        orig.creationDate = Date(timeIntervalSince1970: 1_600_000_000)
        let newID = try await lib.importVideo(exported, preserving: orig)
        #expect(newID.raw == "clip-pare.mov")
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(newID.raw).path)
        #expect((attrs[.creationDate] as? Date) == orig.creationDate)
        let again = try await lib.importVideo(exported, preserving: orig)
        #expect(again != newID)

        try await lib.delete([original.id])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("clip.mov").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".trash/clip.mov").path))
        let remaining = try await lib.items().map(\.id.raw)
        #expect(!remaining.contains("clip.mov") && remaining.contains("clip-pare.mov"))
        await #expect(throws: LibraryError.self) { try await lib.delete([original.id]) }
        #expect(await lib.authorization() == .full)
    }
}
