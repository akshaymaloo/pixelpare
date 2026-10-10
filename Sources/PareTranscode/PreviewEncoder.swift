import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import PareCore

public enum PreviewEncoder {
    public static let rangeSpread = 0.10

    /// A short preview encode taken from the middle of a video. The caller owns (and must delete) `url`'s directory.
    public struct PreviewClip: Sendable {
        public let url: URL
        /// Where in the source the clip starts, in seconds.
        public let sourceStart: Double
        public let duration: Double
        public let estimate: SizeEstimate
        public func cleanup() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    /// Encodes a short clip from the middle of the video and extrapolates the full-file size.
    public static func sampleEstimate(input: URL, settings: EncodeSettings,
                                      seconds: Double = 5) async throws -> SizeEstimate {
        let clip = try await previewClip(input: input, settings: settings, seconds: seconds)
        clip.cleanup()
        return clip.estimate
    }

    public static func previewClip(input: URL, settings: EncodeSettings,
                                   seconds: Double = 5) async throws -> PreviewClip {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw TranscodeError.noVideoTrack }
        let clip = min(max(seconds, 0.5), duration)
        let start = max(0, (duration - clip) / 2)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: clip, preferredTimescale: 600))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pare-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("preview.mov")
        do {
            try await Transcoder().transcode(input: input, output: out, settings: settings,
                                             timeRange: range) { _ in }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let bytes = Double(Verifier.fileSize(out)) * duration / clip
        let estimate = SizeEstimate(state: .previewReady,
                                    low: Int64(bytes * (1 - rangeSpread)), high: Int64(bytes * (1 + rangeSpread)))
        return PreviewClip(url: out, sourceStart: start, duration: clip, estimate: estimate)
    }

    /// A single frame (orientation applied), longest side ≤ `maxPixel`, for the A/B compare view.
    public static func extractFrame(from url: URL, at time: CMTime, maxPixel: Int) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try await generator.image(at: time).image
    }
}
