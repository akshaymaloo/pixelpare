import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum FixtureError: Error { case failed(String) }

/// Generates synthetic Motion-JPEG + AAC test videos (moving noise so encoding is non-trivial).
enum Fixtures {
    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pare-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func make(at url: URL, width: Int = 1280, height: Int = 720, seconds: Double = 3,
                     fps: Int = 30, bitrate: Int = 20_000_000, rotate90: Bool = false,
                     audio: Bool = true) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            // Motion-JPEG is encoded in software. Hardware H.264/HEVC sessions in parallel test
            // runs panicked macOS 27.0.1 (dart-ave0 PTE invalid, AppleT8110DART), see docs/resilience.md.
            AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.9],
        ])
        if rotate90 { vin.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(vin)
        var ain: AVAssetWriterInput?
        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100, AVEncoderBitRateKey: 64_000,
            ])
            writer.add(a); ain = a
        }
        guard writer.startWriting() else { throw FixtureError.failed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        var rng = SystemRandomNumberGenerator()
        let noise = (0..<(width * height * 4)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let frames = Int(seconds * Double(fps))
        var pos = 0
        let rate = 44_100, chunk = 1024
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        let total = Int(seconds * Double(rate))
        // Audio and video must be interleaved or the writer stalls waiting for the other input.
        func pushAudio(until limit: Double) async throws {
            guard let ain else { return }
            while pos < total, Double(pos) / Double(rate) <= limit {
                let n = min(chunk, total - pos)
                var samples = (0..<n).map { Int16(10_000 * sin(2 * Double.pi * 440 * Double(pos + $0) / Double(rate))) }
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 2,
                    blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: n * 2,
                    flags: 0, blockBufferOut: &block)
                CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0,
                                              dataLength: n * 2)
                var sb: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!,
                    formatDescription: fmt!, sampleCount: n,
                    presentationTimeStamp: CMTime(value: Int64(pos), timescale: Int32(rate)),
                    packetDescriptions: nil, sampleBufferOut: &sb)
                while !ain.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                ain.append(sb!)
                pos += n
            }
        }
        for i in 0..<frames {
            try await pushAudio(until: Double(i) / Double(fps) + 0.2)
            while !vin.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw FixtureError.failed("pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { throw FixtureError.failed("buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let shift = (i * 12) % width
            noise.withUnsafeBufferPointer { n in
                for y in 0..<height {
                    let row = base + y * stride
                    let src = n.baseAddress! + y * width * 4
                    let first = (width - shift) * 4
                    memcpy(row, src + shift * 4, first)
                    memcpy(row + first, src, shift * 4)
                    row[0] = UInt8((y + i * 4) % 256)
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps)))
        }
        vin.markAsFinished()
        try await pushAudio(until: .infinity)
        ain?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError.failed(writer.error?.localizedDescription ?? "finish") }
    }
}

/// Tests that run real HEVC encodes are opt-in. Safe on this Mac: `PIXELPARE_SOFTWARE_ENCODE=1 swift test --no-parallel`
/// (software encoder). Hardware: `PIXELPARE_HW_ENCODE_TESTS=1` — macOS 27.0.1 kernel-panicked (dart-ave0) under
/// parallel/cancelled hardware encode sessions from test runs.
enum HardwareEncode {
    static let enabled = ProcessInfo.processInfo.environment["PIXELPARE_HW_ENCODE_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["PIXELPARE_SOFTWARE_ENCODE"] == "1"
}
