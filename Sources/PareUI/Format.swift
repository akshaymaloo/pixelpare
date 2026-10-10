import Foundation
import PareCore
import SwiftUI

enum Brand {
    static let teal = Color(red: 0x14 / 255, green: 0xB8 / 255, blue: 0xA6 / 255)
    static let blue = Color(red: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255)
    static let gradient = LinearGradient(colors: [teal, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let keep = Color(red: 0.19, green: 0.78, blue: 0.35)
}

enum Format {
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: b)
    }

    /// "4.2–6.1 GB" when both ends share a unit, otherwise "980 MB–1.2 GB"; one value when the ends are equal.
    static func range(_ r: ClosedRange<Int64>) -> String {
        let lo = bytes(r.lowerBound), hi = bytes(r.upperBound)
        if lo == hi { return hi }
        let loParts = lo.split(separator: " "), hiParts = hi.split(separator: " ")
        if loParts.count == 2, hiParts.count == 2, loParts[1] == hiParts[1] {
            return "\(loParts[0])–\(hi)"
        }
        return "\(lo)–\(hi)"
    }

    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "Unknown date" }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func resolution(_ item: MediaItem) -> String {
        let long = max(item.pixelWidth, item.pixelHeight)
        switch long {
        case 3000...: return "4K"
        case 1900...: return "1080p"
        case 1200...: return "720p"
        case 1...: return "\(item.pixelWidth)×\(item.pixelHeight)"
        default: return "Video"
        }
    }

    static func videoDetail(_ item: MediaItem) -> String {
        var parts = [resolution(item)]
        if let f = item.frameRate { parts.append("\(Int(f.rounded())) fps") }
        if let c = item.videoCodec?.lowercased() {
            parts.append(["hevc", "hvc1", "hev1", "h265"].contains(c) ? "HEVC" : ["avc1", "h264"].contains(c) ? "H.264" : c.uppercased())
        }
        parts.append(item.isLocal ? "on this device" : "in iCloud only")
        return parts.joined(separator: " · ")
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}

extension VideoPreset {
    var title: String {
        switch self {
        case .gentle: "Gentle"
        case .balanced: "Balanced"
        case .smallerResolution: "Compact"
        }
    }
    var summary: String {
        switch self {
        case .gentle: "Least compression. Keeps resolution & frame rate."
        case .balanced: "Smaller files. Keeps resolution; fine detail may change."
        case .smallerResolution: "4K → 1080p, same frame rate. More detail loss on big screens."
        }
    }
    var shortSummary: String {
        switch self {
        case .gentle: "Keeps resolution"
        case .balanced: "Smaller, keeps resolution"
        case .smallerResolution: "4K → 1080p"
        }
    }
}
