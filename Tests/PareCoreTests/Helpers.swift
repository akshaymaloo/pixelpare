import Foundation
@testable import PareCore

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func mid(_ s: String) -> MediaID { MediaID(s) }

func photo(_ s: String, at offset: TimeInterval = 0, w: Int = 4000, h: Int = 3000, fav: Bool = false,
           burst: String? = nil, size: Int64? = 3_000_000, kind: MediaKind = .photo) -> MediaItem {
    MediaItem(id: mid(s), kind: kind, creationDate: t0.addingTimeInterval(offset), pixelWidth: w,
              pixelHeight: h, byteSize: size, isFavorite: fav, burstID: burst)
}

func video(_ s: String, w: Int = 3840, h: Int = 2160, fps: Double = 30, dur: TimeInterval = 60,
           size: Int64? = 400_000_000, codec: String = "avc1") -> MediaItem {
    MediaItem(id: mid(s), kind: .video, creationDate: t0, pixelWidth: w, pixelHeight: h, byteSize: size,
              duration: dur, videoCodec: codec, frameRate: fps)
}

/// Feature print on the unit circle at `degrees`; L2 distance between angles a,b = 2 sin(|a-b|/2).
func sig(_ s: String, hash: UInt64 = 0, degrees: Double = 0, rev: Int = 1, sharp: Double = 100,
         aes: Double? = nil, face: Double? = nil) -> ImageSignals {
    let r = degrees * .pi / 180
    return ImageSignals(id: mid(s), dHash: hash, featurePrint: [Float(cos(r)), Float(sin(r))],
                        featurePrintRevision: rev, sharpness: sharp, aesthetics: aes, faceQuality: face)
}

func index(_ items: [MediaItem]) -> [MediaID: MediaItem] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
}
func index(_ s: [ImageSignals]) -> [MediaID: ImageSignals] {
    Dictionary(uniqueKeysWithValues: s.map { ($0.id, $0) })
}

func tempJournalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("pare-journal-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("journal.json")
}
