import Foundation

public enum VideoPreset: String, CaseIterable, Codable, Sendable { case gentle, balanced, smallerResolution }

public struct EncodeSettings: Codable, Sendable, Equatable {
    public var codec: String
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var quality: Double?
    public var bitsPerPixel: Double
    public var keepAudio: Bool

    public init(codec: String = "hvc1", width: Int, height: Int, frameRate: Double,
                quality: Double?, bitsPerPixel: Double, keepAudio: Bool = true) {
        self.codec = codec; self.width = width; self.height = height; self.frameRate = frameRate
        self.quality = quality; self.bitsPerPixel = bitsPerPixel; self.keepAudio = keepAudio
    }
}

public enum SkipReason: String, Codable, Sendable, Equatable {
    case notVideo, hdr, slowMo, edited, alreadyEfficient, tooShort, tooSmall

    public var message: String {
        switch self {
        case .notVideo: "Not a video"
        case .hdr: "HDR video isn't supported yet"
        case .slowMo: "Slo-mo video isn't supported"
        case .edited: "Edited video would lose its edits"
        case .alreadyEfficient: "Already optimized"
        case .tooShort: "Too short to be worth compressing"
        case .tooSmall: "Too small to be worth compressing"
        }
    }
}

public enum Eligibility: Sendable, Equatable {
    case eligible
    case skipped(SkipReason)
    public var isEligible: Bool { self == .eligible }
}

public struct SizeEstimate: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case estimate, previewReady, final }
    public var state: State
    public var low: Int64
    public var high: Int64
    public init(state: State = .estimate, low: Int64, high: Int64) {
        self.state = state; self.low = low; self.high = high
    }
}

public enum PresetPolicy {
    public static let minDuration: TimeInterval = 3
    public static let minByteSize: Int64 = 20_000_000
    /// HEVC files below this bits-per-pixel are considered already efficient.
    public static let efficientBitsPerPixel = 0.08
    public static let maxLongEdgeForSmaller = 1920
    public static let audioBitsPerSecond = 128_000.0
    public static let estimateSpread = 0.15
    static let defaultFrameRate = 30.0

    public static func eligibility(_ item: MediaItem) -> Eligibility {
        guard item.kind == .video else { return .skipped(.notVideo) }
        if item.isHDR { return .skipped(.hdr) }
        if item.isSlowMo { return .skipped(.slowMo) }
        if item.isEdited { return .skipped(.edited) }
        if let d = item.duration, d < minDuration { return .skipped(.tooShort) }
        if let b = item.byteSize, b < minByteSize { return .skipped(.tooSmall) }
        if let codec = item.videoCodec?.lowercased(), ["hevc", "hvc1", "hev1", "h265"].contains(codec),
           let bpp = currentBitsPerPixel(item), bpp < efficientBitsPerPixel {
            return .skipped(.alreadyEfficient)
        }
        return .eligible
    }

    public static func settings(for item: MediaItem, preset: VideoPreset) -> EncodeSettings? {
        guard item.pixelWidth > 0, item.pixelHeight > 0 else { return nil }
        let fps = item.frameRate ?? defaultFrameRate
        var w = item.pixelWidth, h = item.pixelHeight
        let bpp: Double, quality: Double
        switch preset {
        case .gentle: bpp = 0.10; quality = 0.75
        case .balanced: bpp = 0.07; quality = 0.62
        case .smallerResolution:
            bpp = 0.07; quality = 0.62
            let long = max(w, h)
            guard long > maxLongEdgeForSmaller else { return nil }
            let scale = Double(maxLongEdgeForSmaller) / Double(long)
            w = Int((Double(w) * scale).rounded(.down)); h = Int((Double(h) * scale).rounded(.down))
        }
        return EncodeSettings(width: even(w), height: even(h), frameRate: fps,
                              quality: quality, bitsPerPixel: bpp)
    }

    public static func estimate(_ item: MediaItem, preset: VideoPreset) -> SizeEstimate {
        let original = item.byteSize
        guard let duration = item.duration, duration > 0,
              let s = settings(for: item, preset: preset) else {
            // Preset not applicable: no saving expected.
            return SizeEstimate(low: original ?? 0, high: original ?? 0)
        }
        let video = s.bitsPerPixel * Double(s.width) * Double(s.height) * s.frameRate * duration / 8
        let audio = s.keepAudio ? audioBitsPerSecond * duration / 8 : 0
        let mid = video + audio
        var high = Int64(mid * (1 + estimateSpread))
        var low = Int64(mid * (1 - estimateSpread))
        if let original { high = min(high, original); low = min(low, high) }
        return SizeEstimate(low: low, high: high)
    }

    /// Bytes per second approximated when the original size is unknown.
    static func currentBitsPerPixel(_ item: MediaItem) -> Double? {
        guard let bytes = item.byteSize, let d = item.duration, d > 0, item.pixelCount > 0 else { return nil }
        let fps = item.frameRate ?? defaultFrameRate
        return Double(bytes) * 8 / (Double(item.pixelCount) * fps * d)
    }

    private static func even(_ v: Int) -> Int { max(2, v - v % 2) }
}
