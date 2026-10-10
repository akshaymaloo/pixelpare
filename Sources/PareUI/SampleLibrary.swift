import CoreGraphics
import Foundation
import PareCore
import PareLibrary
import Synchronization

/// In-memory library with generated images, for SwiftUI previews and `PIXELPARE_SAMPLE=1` demo launches.
/// It never touches Photos or the file system.
public final class SampleLibrary: MediaLibrary {
    private struct Spec { var item: MediaItem; var seed: Int; var brightness: Double; var hash: String?; var screenshot: Bool; var blur = false }
    private let specs: Mutex<[Spec]>

    public init(now: Date = Date()) {
        var out: [Spec] = []
        let day: TimeInterval = 86_400
        func add(_ id: String, kind: MediaKind = .photo, age: Double, seed: Int, brightness: Double = 0,
                 hash: String? = nil, size: Int64 = 3_400_000, favorite: Bool = false, blur: Bool = false) {
            let item = MediaItem(id: MediaID(id), kind: kind,
                                 creationDate: now.addingTimeInterval(-age * day),
                                 pixelWidth: kind == .screenshot ? 1170 : 4032,
                                 pixelHeight: kind == .screenshot ? 2532 : 3024,
                                 byteSize: size, isFavorite: favorite)
            out.append(Spec(item: item, seed: seed, brightness: brightness, hash: hash, screenshot: kind == .screenshot, blur: blur))
        }
        for g in 0..<4 {
            let age = Double(5 + g * 9)
            for v in 0..<(g == 1 ? 3 : 4) {
                add("group\(g)-\(v).jpg", age: age + Double(v) * 0.0001, seed: 10 + g, brightness: Double(v) * 0.02,
                    hash: v == 3 ? "exact-\(g)" : (v == 2 && g == 0 ? "exact-\(g)" : nil),
                    size: 3_000_000 + Int64(v) * 700_000, favorite: g == 1 && v == 2)
            }
        }
        for s in 0..<6 { add("single\(s).jpg", age: Double(3 + s * 7), seed: 40 + s * 3) }
        for s in 0..<3 { add("blurry\(s).jpg", age: Double(12 + s * 17), seed: 120 + s * 5, size: 2_600_000, blur: true) }
        for s in 0..<8 {
            add("Screenshot \(s).png", kind: .screenshot, age: Double(s < 6 ? 45 + s * 10 : 5), seed: 90 + s, size: 900_000)
        }
        let gb: Int64 = 1_000_000_000
        func video(_ id: String, w: Int, h: Int, fps: Double, codec: String, bytes: Int64, secs: Double,
                   local: Bool = true, hdr: Bool = false, seed: Int, age: Double) {
            out.append(Spec(item: MediaItem(id: MediaID(id), kind: .video,
                                            creationDate: now.addingTimeInterval(-age * day),
                                            pixelWidth: w, pixelHeight: h, byteSize: bytes, isLocal: local,
                                            duration: secs, videoCodec: codec, frameRate: fps, isHDR: hdr),
                            seed: seed, brightness: 0, hash: nil, screenshot: false))
        }
        video("Beach day.mov", w: 3840, h: 2160, fps: 60, codec: "avc1", bytes: 38 * gb / 10, secs: 724, seed: 70, age: 20)
        video("Road trip.mov", w: 3840, h: 2160, fps: 30, codec: "hvc1", bytes: 19 * gb / 10, secs: 312, local: false, seed: 71, age: 40)
        video("Concert.mov", w: 1920, h: 1080, fps: 30, codec: "hvc1", bytes: 60_000_000, secs: 150, seed: 72, age: 60)
        video("Ski run.mov", w: 3840, h: 2160, fps: 30, codec: "hvc1", bytes: 6 * gb / 10, secs: 45, hdr: true, seed: 73, age: 80)
        specs = Mutex(out)
    }

    public func authorization() async -> LibraryAccess { .full }
    public func requestAccess() async -> LibraryAccess { .full }
    public func items() async throws -> [MediaItem] { specs.withLock { $0.map(\.item) } }

    public func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage {
        guard let s = specs.withLock({ $0.first { $0.item.id == id } }) else { throw LibraryError.notFound(id.raw) }
        let tall = s.item.pixelHeight > s.item.pixelWidth
        let w = tall ? maxPixel * 2 / 3 : maxPixel, h = tall ? maxPixel : maxPixel * 3 / 4
        return Self.render(seed: s.seed, brightness: s.brightness, screenshot: s.screenshot, width: w, height: h, blur: s.blur)
    }

    public func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool,
                            progress: @Sendable (Double) -> Void) async throws -> URL {
        throw LibraryError.exportFailed("Sample videos have no media")
    }

    public func exactHash(_ id: MediaID) async throws -> String? {
        specs.withLock { $0.first { $0.item.id == id }?.hash }
    }

    public func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID {
        throw LibraryError.importFailed("Sample library is read-only")
    }

    public func delete(_ ids: [MediaID]) async throws {
        let set = Set(ids)
        specs.withLock { $0.removeAll { set.contains($0.item.id) } }
    }

    static func render(seed: Int, brightness: Double, screenshot: Bool, width: Int, height: Int, blur: Bool = false) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func hue(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
            let c = 1 - abs(2 * b - 1), hh = (h.truncatingRemainder(dividingBy: 1)) * 6
            let x = c * s * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
            let m = b - c * s / 2
            let (r, g, bl): (Double, Double, Double) = switch Int(hh) {
            case 0: (c * s, x, 0); case 1: (x, c * s, 0); case 2: (0, c * s, x)
            case 3: (0, x, c * s); case 4: (x, 0, c * s); default: (c * s, 0, x)
            }
            return CGColor(red: r + m, green: g + m, blue: bl + m, alpha: 1)
        }
        let rnd = { (n: Int) -> Double in
            var z = UInt64(truncatingIfNeeded: seed &* 7919 &+ n &* 104_729) &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) % 10_000) / 10_000
        }
        let W = CGFloat(width), H = CGFloat(height)
        if screenshot {
            ctx.setFillColor(CGColor(gray: 0.96, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            for r in 0..<8 {
                ctx.setFillColor(hue(rnd(r), 0.6, 0.6))
                ctx.fill(CGRect(x: W * 0.08, y: H * (0.1 + 0.105 * CGFloat(r)), width: W * (0.4 + 0.5 * rnd(r + 20)), height: H * 0.06))
            }
        } else {
            let g = CGGradient(colorsSpace: cs, colors: [hue(rnd(1), 0.7, 0.55), hue(rnd(2), 0.7, 0.35)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
            for i in 0..<5 {
                ctx.setFillColor(hue(rnd(10 + i), 0.5, 0.7).copy(alpha: 0.85)!)
                let r = W * (0.1 + 0.15 * rnd(30 + i))
                ctx.fillEllipse(in: CGRect(x: W * rnd(40 + i) - r, y: H * rnd(50 + i) - r, width: r * 2, height: r * 2))
            }
        }
        if !screenshot {
            // Fine detail so ordinary samples read as sharp; blurry ones skip it.
            if !blur {
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55)); ctx.setLineWidth(max(1, W / 160))
                for i in 0..<28 {
                    let x = W * rnd(200 + i), y = H * rnd(300 + i)
                    ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + W * 0.12 * (rnd(400 + i) - 0.5), y: y + H * 0.12 * (rnd(500 + i) - 0.5)))
                }
                ctx.strokePath()
            }
        }
        if brightness != 0 {
            ctx.setFillColor(CGColor(gray: brightness > 0 ? 1 : 0, alpha: abs(brightness)))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        let image = ctx.makeImage()!
        guard blur, let small = Self.scaled(image, width: max(4, width / 12), height: max(3, height / 12)) else { return image }
        return Self.scaled(small, width: width, height: height) ?? image
    }

    private static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
