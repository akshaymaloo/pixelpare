import Foundation

public struct ImageSignals: Codable, Sendable {
    public let id: MediaID
    public let dHash: UInt64
    public let featurePrint: [Float]
    public let featurePrintRevision: Int
    public let sharpness: Double
    public let aesthetics: Double?
    public let faceQuality: Double?

    public init(
        id: MediaID, dHash: UInt64, featurePrint: [Float], featurePrintRevision: Int,
        sharpness: Double, aesthetics: Double? = nil, faceQuality: Double? = nil
    ) {
        self.id = id; self.dHash = dHash; self.featurePrint = featurePrint
        self.featurePrintRevision = featurePrintRevision; self.sharpness = sharpness
        self.aesthetics = aesthetics; self.faceQuality = faceQuality
    }

    public func hammingDistance(to other: ImageSignals) -> Int {
        (dHash ^ other.dHash).nonzeroBitCount
    }

    /// L2 distance between L2-normalised feature prints. nil if incomparable
    /// (different revision, different length, or a zero vector).
    public func featureDistance(to other: ImageSignals) -> Double? {
        guard featurePrintRevision == other.featurePrintRevision,
              featurePrint.count == other.featurePrint.count, !featurePrint.isEmpty,
              let a = Self.normalized(featurePrint), let b = Self.normalized(other.featurePrint)
        else { return nil }
        var sum = 0.0
        for i in 0..<a.count { let d = a[i] - b[i]; sum += d * d }
        return sum.squareRoot()
    }

    static func normalized(_ v: [Float]) -> [Double]? {
        var norm = 0.0
        for x in v { norm += Double(x) * Double(x) }
        norm = norm.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return v.map { Double($0) / norm }
    }
}
