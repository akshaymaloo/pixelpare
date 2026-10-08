import AVFoundation
import CoreMedia
import Foundation
import PareCore
import Testing
@testable import PareTranscode

@Suite(.serialized)
struct TranscoderTests {
    static func balanced() -> EncodeSettings {
        EncodeSettings(width: 1280, height: 720, frameRate: 30, quality: 0.62, bitsPerPixel: 0.07)
    }

    @Test func balancedTranscodeIsHEVCAndVerifies() async throws {
        let dir = try Fixtures.makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.mov"), out = dir.appendingPathComponent("b.mov")
        try await Fixtures.make(at: src)
        let last = LastValue()
        try await Transcoder().transcode(input: src, output: out, settings: Self.balanced()) { last.set($0) }
        #expect(last.get() == 1)
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let fmt = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(fmt) == kCMVideoCodecType_HEVC)
        let report = try await Verifier.verify(original: src, encoded: out)
        #expect(report.passed, "\(report.failures)")
        #expect(report.savingsFraction > 0.15)
        #expect(report.encodedAudioTracks == 1)
    }

    @Test func rotationTransformPreserved() async throws {
        let dir = try Fixtures.makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("r.mov"), out = dir.appendingPathComponent("r2.mov")
        try await Fixtures.make(at: src, rotate90: true)
        try await Transcoder().transcode(input: src, output: out, settings: Self.balanced()) { _ in }
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let t = try await track.load(.preferredTransform)
        #expect(abs(t.b - 1) < 0.001 && abs(t.c + 1) < 0.001)
        let report = try await Verifier.verify(original: src, encoded: out)
        #expect(report.passed, "\(report.failures)")
        #expect(report.displayWidth == 720 && report.displayHeight == 1280)
    }

    @Test func scaledPresetProducesExpectedDimensions() async throws {
        let dir = try Fixtures.makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("s.mov"), out = dir.appendingPathComponent("s2.mov")
        try await Fixtures.make(at: src, rotate90: true)
        // Natural-orientation settings (640x360) and display-orientation settings (360x640) both work.
        var s = Self.balanced(); s.width = 640; s.height = 360
        try await Transcoder().transcode(input: src, output: out, settings: s) { _ in }
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 640, height: 360))
        let report = try await Verifier.verify(original: src, encoded: out,
                                               expectedDisplaySize: CGSize(width: 360, height: 640))
        #expect(report.passed, "\(report.failures)")

        s.width = 360; s.height = 640
        try await Transcoder().transcode(input: src, output: out, settings: s) { _ in }
        let t2 = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        #expect(try await t2.load(.naturalSize) == CGSize(width: 640, height: 360))
    }

    @Test func cancellationRemovesPartialOutput() async throws {
        let dir = try Fixtures.makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("c.mov"), out = dir.appendingPathComponent("c2.mov")
        try await Fixtures.make(at: src)
        let task = Task { try await Transcoder().transcode(input: src, output: out, settings: Self.balanced()) { _ in } }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func verifierFailsOnInsufficientSavingsAndDurationMismatch() async throws {
        let dir = try Fixtures.makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"), b = dir.appendingPathComponent("b.mov")
        try await Fixtures.make(at: a, seconds: 3)
        try await Fixtures.make(at: b, seconds: 2)
        let same = try await Verifier.verify(original: a, encoded: a)
        #expect(!same.passed)
        #expect(same.failures.contains { $0.hasPrefix("Savings") })
        let diff = try await Verifier.verify(original: a, encoded: b, minSavings: -1)
        #expect(!diff.passed)
        #expect(diff.failures.contains { $0.hasPrefix("Duration") })
    }

    @Test func sampleEstimateIsPreviewReadyWithSensibleRange() async throws {
        let dir = try Fixtures.makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("p.mov"), out = dir.appendingPathComponent("p2.mov")
        try await Fixtures.make(at: src, seconds: 4)
        let est = try await PreviewEncoder.sampleEstimate(input: src, settings: Self.balanced(), seconds: 2)
        #expect(est.state == .previewReady)
        #expect(est.low > 0 && est.low < est.high)
        #expect(est.high < Verifier.fileSize(src))
        try await Transcoder().transcode(input: src, output: out, settings: Self.balanced()) { _ in }
        let actual = Verifier.fileSize(out)
        #expect(Double(est.high) > Double(actual) * 0.5 && Double(est.low) < Double(actual) * 2)
        let img = try await PreviewEncoder.extractFrame(from: src, at: CMTime(seconds: 1, preferredTimescale: 600), maxPixel: 400)
        #expect(max(img.width, img.height) <= 400)
    }
}

final class LastValue: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0.0
    func set(_ x: Double) { lock.lock(); v = x; lock.unlock() }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return v }
}
