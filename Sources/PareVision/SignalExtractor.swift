import CoreGraphics
import Foundation
import PareCore
import Vision

public enum SignalExtractorError: Error, Sendable {
    case invalidImage
    case featurePrintUnavailable
}

public enum SignalExtractor {
    /// Pinned so stored feature prints stay comparable across OS updates.
    public static let featurePrintRevision = VNGenerateImageFeaturePrintRequestRevision2

    public static func signals(for image: CGImage, id: MediaID) async throws -> ImageSignals {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try compute(image, id: id)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    static func compute(_ image: CGImage, id: MediaID) throws -> ImageSignals {
        guard image.width > 0, image.height > 0 else { throw SignalExtractorError.invalidImage }
        guard let hash = dHash(image), let sharp = sharpness(image) else {
            throw SignalExtractorError.invalidImage
        }

        let featureReq = VNGenerateImageFeaturePrintRequest()
        featureReq.revision = featurePrintRevision
        let aesthReq = VNCalculateImageAestheticsScoresRequest()
        let faceReq = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        try handler.perform([featureReq])
        guard let obs = featureReq.results?.first, let vector = floats(from: obs) else {
            throw SignalExtractorError.featurePrintUnavailable
        }

        var aesthetics: Double?
        if (try? handler.perform([aesthReq])) != nil,
           let score = aesthReq.results?.first?.overallScore, score.isFinite {
            aesthetics = Double(score)
        }

        var faceQuality: Double?
        if (try? handler.perform([faceReq])) != nil {
            let qualities = (faceReq.results ?? []).compactMap { $0.faceCaptureQuality }
            if let m = qualities.max() { faceQuality = Double(m) }
        }

        return ImageSignals(
            id: id, dHash: hash, featurePrint: vector,
            featurePrintRevision: featurePrintRevision, sharpness: sharp,
            aesthetics: aesthetics, faceQuality: faceQuality)
    }

    static func floats(from obs: VNFeaturePrintObservation) -> [Float]? {
        let n = obs.elementCount
        guard n > 0 else { return nil }
        switch obs.elementType {
        case .float:
            guard obs.data.count >= n * MemoryLayout<Float>.size else { return nil }
            return obs.data.withUnsafeBytes { raw in
                (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            }
        case .double:
            guard obs.data.count >= n * MemoryLayout<Double>.size else { return nil }
            return obs.data.withUnsafeBytes { raw in
                (0..<n).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self)) }
            }
        default:
            return nil
        }
    }

    /// Renders into an 8-bit grayscale buffer of the given size.
    static func grayPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(
                data: p.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }

    static func dHash(_ image: CGImage) -> UInt64? {
        guard let px = grayPixels(image, width: 9, height: 8) else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                hash <<= 1
                if px[y * 9 + x] > px[y * 9 + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    /// Variance of the 4-neighbour Laplacian on a ≤512px grayscale copy, mapped to 0…1.
    static func sharpness(_ image: CGImage) -> Double? {
        let scale = min(1.0, 512.0 / Double(max(image.width, image.height)))
        let w = max(3, Int((Double(image.width) * scale).rounded()))
        let h = max(3, Int((Double(image.height) * scale).rounded()))
        guard let px = grayPixels(image, width: w, height: h) else { return nil }
        var sum = 0.0, sumSq = 0.0
        let count = Double((w - 2) * (h - 2))
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let l = Double(px[i - 1]) + Double(px[i + 1]) + Double(px[i - w]) + Double(px[i + w])
                    - 4 * Double(px[i])
                sum += l; sumSq += l * l
            }
        }
        let mean = sum / count
        let variance = max(0, sumSq / count - mean * mean)
        return 1 - exp(-variance / 500)
    }
}
