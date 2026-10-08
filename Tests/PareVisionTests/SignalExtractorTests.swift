import CoreGraphics
import Foundation
import PareCore
import Testing
@testable import PareVision

func makeImage(width: Int = 256, height: Int = 192, _ draw: (CGContext, Int, Int) -> Void) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, width, height)
    return ctx.makeImage()!
}

func sceneImage(width: Int = 256, height: Int = 192, brightness: CGFloat = 0) -> CGImage {
    makeImage(width: width, height: height) { ctx, w, h in
        let g = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [CGColor(red: 0.1 + brightness, green: 0.2 + brightness, blue: 0.6 + brightness, alpha: 1),
                     CGColor(red: 0.9, green: 0.5 + brightness, blue: 0.2, alpha: 1)] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: w / 8, y: h / 4, width: w / 3, height: h / 2))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.9, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 5 / 8, y: h / 8, width: w / 4, height: w / 4))
    }
}

func noiseImage(seed: UInt64) -> CGImage {
    var rng = seed
    return makeImage { ctx, w, h in
        for y in stride(from: 0, to: h, by: 8) {
            for x in stride(from: 0, to: w, by: 8) {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let r = CGFloat((rng >> 33) & 255) / 255
                let g = CGFloat((rng >> 41) & 255) / 255
                let b = CGFloat((rng >> 49) & 255) / 255
                ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
    }
}

func blurred(_ image: CGImage) -> CGImage {
    // Repeated down/up-scaling gives a cheap blur without CoreImage.
    let small = makeImage(width: image.width / 8, height: image.height / 8) { ctx, w, h in
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return makeImage(width: image.width, height: image.height) { ctx, w, h in
        ctx.interpolationQuality = .high
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
}

@Suite struct SignalExtractorTests {
    @Test func identicalImages() async throws {
        let img = sceneImage()
        let a = try await SignalExtractor.signals(for: img, id: MediaID("a"))
        let b = try await SignalExtractor.signals(for: img, id: MediaID("b"))
        #expect(a.hammingDistance(to: b) == 0)
        #expect(a.featurePrintRevision == SignalExtractor.featurePrintRevision)
        #expect(!a.featurePrint.isEmpty)
        let d = try #require(a.featureDistance(to: b))
        #expect(d < 0.001)
        #expect((0...1).contains(a.sharpness))
    }

    @Test func brightenedResizedCopyIsClose() async throws {
        let a = try await SignalExtractor.signals(for: sceneImage(), id: MediaID("a"))
        let b = try await SignalExtractor.signals(
            for: sceneImage(width: 200, height: 150, brightness: 0.02), id: MediaID("b"))
        #expect(a.hammingDistance(to: b) <= 4)
        let near = try #require(a.featureDistance(to: b))
        let far = try await SignalExtractor.signals(for: noiseImage(seed: 7), id: MediaID("c"))
        let farD = try #require(a.featureDistance(to: far))
        #expect(near < farD)
        #expect(near < 0.35)
    }

    @Test func differentImageIsFarther() async throws {
        let a = try await SignalExtractor.signals(for: sceneImage(), id: MediaID("a"))
        let c = try await SignalExtractor.signals(for: noiseImage(seed: 42), id: MediaID("c"))
        let d = try #require(a.featureDistance(to: c))
        #expect(d > 0.2)
        #expect(a.hammingDistance(to: c) > 4)
    }

    @Test func blurLowersSharpness() async throws {
        let sharp = try await SignalExtractor.signals(for: noiseImage(seed: 3), id: MediaID("s"))
        let soft = try await SignalExtractor.signals(for: blurred(noiseImage(seed: 3)), id: MediaID("b"))
        #expect(soft.sharpness < sharp.sharpness)
        #expect(sharp.faceQuality == nil)
    }
}
