import AVFoundation
import CoreMedia
import Foundation

public struct VerificationReport: Codable, Sendable, Equatable {
    public var passed: Bool
    public var failures: [String]
    public var originalBytes: Int64
    public var encodedBytes: Int64
    public var savingsFraction: Double
    public var originalDuration: Double
    public var encodedDuration: Double
    public var durationDelta: Double
    public var originalFrameCount: Int
    public var encodedFrameCount: Int
    public var originalAudioTracks: Int
    public var encodedAudioTracks: Int
    public var displayWidth: Int
    public var displayHeight: Int
}

public enum Verifier {
    public static let durationTolerance = 0.1
    public static let frameCountTolerance = 0.02

    /// `expectedDisplaySize` is the post-transform size expected for the encoded file (pass it when the
    /// preset scaled the video); nil means "same as the original".
    public static func verify(original: URL, encoded: URL, minSavings: Double = 0.15,
                              expectedDisplaySize: CGSize? = nil) async throws -> VerificationReport {
        var failures: [String] = []
        let oBytes = Self.fileSize(original), eBytes = Self.fileSize(encoded)
        let savings = oBytes > 0 ? 1 - Double(eBytes) / Double(oBytes) : 0

        let oAsset = AVURLAsset(url: original), eAsset = AVURLAsset(url: encoded)
        let oDur = try await oAsset.load(.duration).seconds
        let eDur: Double
        let eVideo: AVAssetTrack?
        let eAudioCount: Int
        do {
            eDur = try await eAsset.load(.duration).seconds
            eVideo = try await eAsset.loadTracks(withMediaType: .video).first
            eAudioCount = try await eAsset.loadTracks(withMediaType: .audio).count
        } catch {
            return VerificationReport(passed: false, failures: ["Encoded file is unreadable: \(error.localizedDescription)"],
                                      originalBytes: oBytes, encodedBytes: eBytes, savingsFraction: savings,
                                      originalDuration: oDur, encodedDuration: 0, durationDelta: oDur,
                                      originalFrameCount: 0, encodedFrameCount: 0, originalAudioTracks: 0,
                                      encodedAudioTracks: 0, displayWidth: 0, displayHeight: 0)
        }
        let oVideo = try await oAsset.loadTracks(withMediaType: .video).first
        let oAudioCount = try await oAsset.loadTracks(withMediaType: .audio).count

        let delta = abs(eDur - oDur)
        if !(delta <= durationTolerance) { failures.append(String(format: "Duration differs by %.2f s", delta)) }
        if eAudioCount != oAudioCount { failures.append("Audio track count \(eAudioCount) ≠ \(oAudioCount)") }

        var oFrames = 0, eFrames = 0, dw = 0, dh = 0
        if let eVideo, let oVideo {
            let (oNat, oT, oFmt) = try await oVideo.load(.naturalSize, .preferredTransform, .formatDescriptions)
            let (eNat, eT, eFmt) = try await eVideo.load(.naturalSize, .preferredTransform, .formatDescriptions)
            let eDisp = eNat.applying(eT), oDisp = oNat.applying(oT)
            dw = Int(abs(eDisp.width).rounded()); dh = Int(abs(eDisp.height).rounded())
            let want = expectedDisplaySize ?? CGSize(width: abs(oDisp.width), height: abs(oDisp.height))
            if abs(CGFloat(dw) - want.width) > 1 || abs(CGFloat(dh) - want.height) > 1 {
                failures.append("Display size \(dw)×\(dh) ≠ expected \(Int(want.width))×\(Int(want.height))")
            }
            if !Self.transformsEqual(oT, eT) { failures.append("Orientation transform changed") }
            if let op = Self.primaries(oFmt.first), Self.primaries(eFmt.first) != op {
                failures.append("Color primaries changed")
            }
            if let codec = eFmt.first.map({ CMFormatDescriptionGetMediaSubType($0) }), codec != kCMVideoCodecType_HEVC {
                failures.append("Encoded video is not HEVC")
            }
            oFrames = try await countFrames(oVideo)
            do { eFrames = try await countFrames(eVideo) } catch {
                failures.append("Encoded video is not fully decodable: \(error.localizedDescription)")
            }
            if oFrames > 0, Double(abs(eFrames - oFrames)) / Double(oFrames) > frameCountTolerance {
                failures.append("Frame count \(eFrames) vs \(oFrames)")
            }
        } else {
            failures.append("Missing video track")
        }

        if savings < minSavings {
            failures.append(String(format: "Savings %.1f%% below required %.0f%%", savings * 100, minSavings * 100))
        }
        return VerificationReport(passed: failures.isEmpty, failures: failures, originalBytes: oBytes,
                                  encodedBytes: eBytes, savingsFraction: savings, originalDuration: oDur,
                                  encodedDuration: eDur, durationDelta: delta, originalFrameCount: oFrames,
                                  encodedFrameCount: eFrames, originalAudioTracks: oAudioCount,
                                  encodedAudioTracks: eAudioCount, displayWidth: dw, displayHeight: dh)
    }

    static func fileSize(_ url: URL) -> Int64 {
        let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return n ?? 0
    }

    static func transformsEqual(_ a: CGAffineTransform, _ b: CGAffineTransform) -> Bool {
        abs(a.a - b.a) < 0.001 && abs(a.b - b.b) < 0.001 && abs(a.c - b.c) < 0.001 && abs(a.d - b.d) < 0.001
    }

    static func primaries(_ f: CMFormatDescription?) -> String? {
        guard let f else { return nil }
        return CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
    }

    /// Decodes every video sample; throws if the reader fails.
    static func countFrames(_ track: AVAssetTrack) async throws -> Int {
        guard let asset = track.asset else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else {
            throw reader.error ?? TranscodeError.readerFailed("cannot start")
        }
        let box = ReaderBox(reader: reader, output: out)
        return try await Task.detached { try box.drain() }.value
    }
}

private final class ReaderBox: @unchecked Sendable {
    let reader: AVAssetReader, output: AVAssetReaderTrackOutput
    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) { self.reader = reader; self.output = output }
    func drain() throws -> Int {
        var n = 0
        while let s = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(s) != nil { n += 1 }
        }
        if reader.status == .failed { throw reader.error ?? TranscodeError.readerFailed("decode failed") }
        return n
    }
}
