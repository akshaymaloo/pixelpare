import AVFoundation
import CoreMedia
import Foundation
import PareCore

/// What the exported file actually is, as opposed to what the library metadata claimed.
struct VideoProbe: Sendable {
    var codec: String?
    var frameRate: Double?
    var isHDR: Bool
    var displaySize: CGSize
    var bytes: Int64

    static func load(_ url: URL) async -> VideoProbe? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (nat, transform, fps, formats) = try? await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        else { return nil }
        var codec: String?
        var hdr = false
        if let fd = formats.first {
            switch CMFormatDescriptionGetMediaSubType(fd) {
            case kCMVideoCodecType_HEVC, FourCharCode(0x68657631): codec = "hvc1"
            case kCMVideoCodecType_H264: codec = "avc1"
            case let other: codec = fourCC(other)
            }
            if let t = CMFormatDescriptionGetExtension(
                fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                hdr = t == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || t == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            }
        }
        let display = nat.applying(transform)
        let size = CGSize(width: abs(display.width), height: abs(display.height))
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return VideoProbe(codec: codec, frameRate: fps > 0 ? Double(fps) : nil, isHDR: hdr,
                          displaySize: size, bytes: bytes)
    }

    private static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)],
               encoding: .ascii) ?? "unkn"
    }

    /// Library metadata overlaid with what the file really contains.
    func refine(_ item: MediaItem) -> MediaItem {
        var i = item
        i.videoCodec = codec ?? item.videoCodec
        i.frameRate = frameRate ?? item.frameRate
        i.isHDR = item.isHDR || isHDR
        i.isSlowMo = item.isSlowMo || (frameRate ?? 0) > 60
        if bytes > 0 { i.byteSize = bytes }
        if i.pixelWidth == 0 || i.pixelHeight == 0 {
            i.pixelWidth = Int(displaySize.width); i.pixelHeight = Int(displaySize.height)
        }
        return i
    }
}
