import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import PareCore

public enum PreviewEncoder {
    public static let rangeSpread = 0.10

    /// Encodes a short clip from the middle of the video and extrapolates the full-file size.
    public static func sampleEstimate(input: URL, settings: EncodeSettings,
                                      seconds: Double = 5) async throws -> SizeEstimate {
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
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("preview.mov")

        try await Transcoder().transcode(input: input, output: out, settings: settings,
                                         timeRange: range) { _ in }
        let bytes = Double(Verifier.fileSize(out)) * duration / clip
        return SizeEstimate(state: .previewReady,
                            low: Int64(bytes * (1 - rangeSpread)), high: Int64(bytes * (1 + rangeSpread)))
    }

    /// A single frame (orientation applied), longest side ≤ `maxPixel`, for the A/B compare view.
    public static func extractFrame(from url: URL, at time: CMTime, maxPixel: Int) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try await generator.image(at: time).image
    }
}
