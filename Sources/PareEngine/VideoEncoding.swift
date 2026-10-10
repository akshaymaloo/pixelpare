import AVFoundation
import CoreMedia
import Foundation
import PareCore
import PareTranscode

/// What the exported file actually is, as opposed to what the library metadata claimed.
public struct SourceProbe: Sendable, Equatable {
    public var duration: TimeInterval
    public var bytes: Int64
    public var codec: String?
    public var frameRate: Double?
    public var isHDR: Bool
    public var displayWidth: Int
    public var displayHeight: Int

    public init(duration: TimeInterval, bytes: Int64, codec: String? = nil, frameRate: Double? = nil,
                isHDR: Bool = false, displayWidth: Int = 0, displayHeight: Int = 0) {
        self.duration = duration; self.bytes = bytes; self.codec = codec; self.frameRate = frameRate
        self.isHDR = isHDR; self.displayWidth = displayWidth; self.displayHeight = displayHeight
    }

    /// Library metadata overlaid with what the file really contains.
    public func refine(_ item: MediaItem) -> MediaItem {
        var i = item
        i.videoCodec = codec ?? item.videoCodec
        i.frameRate = frameRate ?? item.frameRate
        i.isHDR = item.isHDR || isHDR
        i.isSlowMo = item.isSlowMo || (frameRate ?? 0) > 60
        if bytes > 0 { i.byteSize = bytes }
        if duration > 0 { i.duration = duration }
        if i.pixelWidth == 0 || i.pixelHeight == 0 { i.pixelWidth = displayWidth; i.pixelHeight = displayHeight }
        return i
    }
}

public struct EncodeVerification: Sendable, Equatable {
    public var passed: Bool
    public var failures: [String]
    public var originalBytes: Int64
    public var encodedBytes: Int64
    public var savingsFraction: Double
    public var displayWidth: Int
    public var displayHeight: Int

    public init(passed: Bool, failures: [String] = [], originalBytes: Int64, encodedBytes: Int64,
                savingsFraction: Double, displayWidth: Int = 0, displayHeight: Int = 0) {
        self.passed = passed; self.failures = failures; self.originalBytes = originalBytes
        self.encodedBytes = encodedBytes; self.savingsFraction = savingsFraction
        self.displayWidth = displayWidth; self.displayHeight = displayHeight
    }
}

/// Transcode + verify, abstracted so tests can script failures. `passed` covers correctness only; the savings
/// threshold is the pipeline's decision.
public protocol VideoEncoding: Sendable {
    /// nil when the file can't be read as a video.
    func probe(_ url: URL) async -> SourceProbe?
    func ladder(for settings: EncodeSettings) -> [EncodeRung]
    func encode(source: URL, output: URL, settings: EncodeSettings, rung: EncodeRung,
                progress: @Sendable (Double) -> Void) async throws
    func verify(source: URL, encoded: URL, settings: EncodeSettings, preset: VideoPreset) async throws -> EncodeVerification
}

public extension VideoEncoding {
    func ladder(for settings: EncodeSettings) -> [EncodeRung] { EncodeRung.ladder(for: settings) }
}

public struct DefaultVideoEncoder: VideoEncoding {
    public init() {}

    public func probe(_ url: URL) async -> SourceProbe? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (nat, transform, fps, formats) = try? await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        else { return nil }
        var codec: String?
        var hdr = false
        if let fd = formats.first {
            switch CMFormatDescriptionGetMediaSubType(fd) {
            case kCMVideoCodecType_HEVC: codec = "hvc1"
            case kCMVideoCodecType_H264: codec = "avc1"
            case let other: codec = Self.fourCC(other)
            }
            if let t = CMFormatDescriptionGetExtension(
                fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                hdr = t == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || t == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            }
        }
        let display = nat.applying(transform)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return SourceProbe(duration: duration.seconds, bytes: bytes, codec: codec,
                           frameRate: fps > 0 ? Double(fps) : nil, isHDR: hdr,
                           displayWidth: Int(abs(display.width).rounded()),
                           displayHeight: Int(abs(display.height).rounded()))
    }

    public func encode(source: URL, output: URL, settings: EncodeSettings, rung: EncodeRung,
                       progress: @Sendable (Double) -> Void) async throws {
        try await Transcoder().transcode(input: source, output: output, settings: settings, rung: rung,
                                         progress: progress)
    }

    public func verify(source: URL, encoded: URL, settings: EncodeSettings,
                       preset: VideoPreset) async throws -> EncodeVerification {
        var expected: CGSize?
        if preset == .smallerResolution, let p = await probe(source) {
            let w = CGFloat(settings.width), h = CGFloat(settings.height)
            let portrait = p.displayHeight > p.displayWidth
            expected = (w > h) == portrait ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        let r = try await Verifier.verify(original: source, encoded: encoded, minSavings: 0,
                                          expectedDisplaySize: expected)
        return EncodeVerification(passed: r.passed, failures: r.failures, originalBytes: r.originalBytes,
                                  encodedBytes: r.encodedBytes, savingsFraction: r.savingsFraction,
                                  displayWidth: r.displayWidth, displayHeight: r.displayHeight)
    }

    private static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)],
               encoding: .ascii) ?? "unkn"
    }
}
