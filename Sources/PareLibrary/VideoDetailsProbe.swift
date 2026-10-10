import AVFoundation
import CoreMedia
import Foundation
import PareCore

enum VideoDetailsProbe {
    /// Codec, frame rate and HDR-ness of the first video track. Reads headers only; never touches the network.
    static func load(_ asset: AVAsset) async -> VideoDetails? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (fps, formats) = try? await track.load(.nominalFrameRate, .formatDescriptions) else { return nil }
        var hdr = track.hasMediaCharacteristic(.containsHDRVideo)
        var codec: String?
        if let fd = formats.first {
            let sub = CMFormatDescriptionGetMediaSubType(fd)
            codec = Self.name(sub)
            // iPhone HDR is usually Dolby Vision HEVC (dvh1) or HLG/PQ 10-bit HEVC.
            if sub == FourCharCode(0x64766831) || sub == FourCharCode(0x64766865) { hdr = true }
            if let t = CMFormatDescriptionGetExtension(
                fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                hdr = hdr || t == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                    || t == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            }
        }
        return VideoDetails(codec: codec, frameRate: fps > 0 ? Double(fps) : nil, isHDR: hdr)
    }

    static func name(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_HEVC: return "hvc1"
        case kCMVideoCodecType_H264: return "avc1"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
