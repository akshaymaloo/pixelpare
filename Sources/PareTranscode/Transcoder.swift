import AVFoundation
import CoreMedia
import Foundation
import PareCore
import VideoToolbox
import os

public enum TranscodeError: Error, Sendable, Equatable, LocalizedError {
    case noVideoTrack
    case cannotConfigure(String)
    case readerFailed(String)
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .cannotConfigure(let m): "Could not configure the encoder: \(m)"
        case .readerFailed(let m): "Reading the video failed: \(m)"
        case .writerFailed(let m): "Writing the video failed: \(m)"
        }
    }
}

/// Encoder fallback ladder: each rung is more conservative than the last.
public enum EncodeRung: Int, CaseIterable, Sendable, Codable {
    /// Average bitrate plus the preset's quality hint.
    case preset
    /// Average bitrate only.
    case bitrateOnly
    /// Average bitrate, and audio decoded and re-encoded as AAC.
    case bitrateWithAAC

    var usesQualityHint: Bool { self == .preset }
    var reencodesAudio: Bool { self == .bitrateWithAAC }

    /// The rungs that make sense for `settings` (no quality rung without a hint, no AAC rung without audio).
    public static func ladder(for settings: EncodeSettings) -> [EncodeRung] {
        var rungs: [EncodeRung] = []
        if settings.quality != nil { rungs.append(.preset) }
        rungs.append(.bitrateOnly)
        if settings.keepAudio { rungs.append(.bitrateWithAAC) }
        return rungs
    }
}

/// Re-encodes a video to HEVC.
///
/// `EncodeSettings.width/height` are interpreted in the video track's *natural* (unrotated) pixel space,
/// which is what the writer encodes; the source `preferredTransform` is copied to the writer input so
/// rotation is never baked in. For robustness, if the settings' orientation matches the *display*
/// orientation of a 90°-rotated track (e.g. Photos' oriented `pixelWidth/Height`), they are swapped.
/// Settings larger than the source are clamped to the source size (never upscaled).
public struct Transcoder: Sendable {
    /// `PIXELPARE_SOFTWARE_ENCODE=1` keeps encodes off the hardware video encoder (AVE). Slower, but it avoids the
    /// macOS 27.0.1 dart-ave0 kernel panic seen with test runs (docs/resilience.md §9).
    public static let softwareEncoderOnly = ProcessInfo.processInfo.environment["PIXELPARE_SOFTWARE_ENCODE"] == "1"

    public init() {}

    public func transcode(input: URL, output: URL, settings: EncodeSettings,
                          progress: @Sendable (Double) -> Void) async throws {
        try await transcode(input: input, output: output, settings: settings, timeRange: nil, progress: progress)
    }

    /// One attempt at a single ladder rung, with no internal fallback: the caller (the pipeline) owns the ladder.
    /// On failure or cancellation the output file is removed.
    public func transcode(input: URL, output: URL, settings: EncodeSettings, rung: EncodeRung,
                          progress: @Sendable (Double) -> Void) async throws {
        try await attempt(rung: rung, input: input, output: output, settings: settings, timeRange: nil,
                          progress: progress)
    }

    private func attempt(rung: EncodeRung, input: URL, output: URL, settings: EncodeSettings,
                         timeRange: CMTimeRange?, progress: @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: output)
        do {
            try await attempt(input: input, output: output, settings: settings, timeRange: timeRange,
                              useQuality: rung.usesQualityHint, reencodeAudio: rung.reencodesAudio,
                              progress: progress)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func transcode(input: URL, output: URL, settings: EncodeSettings, timeRange: CMTimeRange?,
                   progress: @Sendable (Double) -> Void) async throws {
        // Fall back step by step: first drop the quality hint, then re-encode audio.
        var lastError: Error = TranscodeError.cannotConfigure("no encoder rung")
        for rung in EncodeRung.ladder(for: settings) {
            do {
                try await attempt(rung: rung, input: input, output: output, settings: settings,
                                  timeRange: timeRange, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func attempt(input: URL, output: URL, settings: EncodeSettings, timeRange: CMTimeRange?,
                         useQuality: Bool, reencodeAudio: Bool,
                         progress: @Sendable (Double) -> Void) async throws {
        try await EncoderGate.shared.withExclusiveAccess {
            try await attemptExclusive(input: input, output: output, settings: settings, timeRange: timeRange,
                                       useQuality: useQuality, reencodeAudio: reencodeAudio, progress: progress)
        }
    }

    private func attemptExclusive(input: URL, output: URL, settings: EncodeSettings, timeRange: CMTimeRange?,
                                  useQuality: Bool, reencodeAudio: Bool,
                                  progress: @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }
        let (natural, transform, sourceFPS, formats) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        let assetDuration = try await asset.load(.duration)
        let range = timeRange ?? CMTimeRange(start: .zero, duration: assetDuration)
        let totalSeconds = max(range.duration.seconds, 0.001)

        let target = Self.targetSize(settings: settings, natural: natural, transform: transform)
        let fps = settings.frameRate > 0 ? settings.frameRate : Double(sourceFPS > 0 ? sourceFPS : 30)
        let format = formats.first

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let tenBit = Self.isTenBit(format)
        let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                 : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw TranscodeError.cannotConfigure("video reader output") }
        reader.add(videoOut)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(settings.bitsPerPixel * Double(target.width * target.height) * fps),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if tenBit { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        if useQuality, let q = settings.quality { compression[kVTCompressionPropertyKey_Quality as String] = q }

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: target.width,
            AVVideoHeightKey: target.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let color = Self.colorProperties(format) { videoSettings[AVVideoColorPropertiesKey] = color }
        #if os(macOS)
        // AVVideoEncoderSpecificationKey is macOS-only; on iOS the flag has no effect.
        if Self.softwareEncoderOnly {
            videoSettings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: false,
            ]
        }
        #endif
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: nil)
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw TranscodeError.cannotConfigure("video writer input") }
        writer.add(videoIn)

        var pumps = [Pump(output: videoOut, input: videoIn, isVideo: true)]
        if settings.keepAudio {
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let hint = try await track.load(.formatDescriptions).first
                let out: AVAssetReaderTrackOutput
                let inp: AVAssetWriterInput
                if reencodeAudio, let hint, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(hint)?.pointee {
                    out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                    ])
                    inp = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: Int(max(1, min(asbd.mChannelsPerFrame, 2))),
                        AVSampleRateKey: asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100,
                        AVEncoderBitRateKey: 192_000,
                    ])
                } else {
                    out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    inp = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
                }
                out.alwaysCopiesSampleData = false
                inp.expectsMediaDataInRealTime = false
                guard reader.canAdd(out), writer.canAdd(inp) else {
                    throw TranscodeError.cannotConfigure("audio track")
                }
                reader.add(out); writer.add(inp)
                pumps.append(Pump(output: out, input: inp, isVideo: false))
            }
        }

        writer.metadata = await Self.metadata(of: asset)

        guard reader.startReading() else {
            throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: range.start)

        let queue = DispatchQueue(label: "pare.transcode")
        let run = Run(reader: reader, writer: writer, pumps: pumps, queue: queue)
        let start = range.start.seconds
        await withoutActuallyEscaping(progress) { escaping in
        let report = ProgressBox(escaping)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for pump in pumps {
                    group.addTask {
                        await run.pump(pump) { pts in
                            if pump.isVideo { report.send(min(1, max(0, (pts - start) / totalSeconds))) }
                        }
                    }
                }
            }
        } onCancel: {
            run.cancel()
        }
        queue.sync {}
        report.close()
        }

        if Task.isCancelled || run.isCancelled {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        if writer.status == .failed {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.endSession(atSourceTime: range.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        progress(1)
    }

    static func targetSize(settings: EncodeSettings, natural: CGSize, transform: CGAffineTransform)
        -> (width: Int, height: Int) {
        let nw = Int(natural.width.rounded()), nh = Int(natural.height.rounded())
        var w = settings.width, h = settings.height
        let rotated = abs(transform.b) > 0.5 && abs(transform.c) > 0.5
        if rotated, nw != nh, w != h, (w > h) != (nw > nh) { swap(&w, &h) }
        w = min(w, nw); h = min(h, nh)
        return (max(2, w - w % 2), max(2, h - h % 2))
    }

    static func isTenBit(_ format: CMFormatDescription?) -> Bool {
        guard let format else { return false }
        if let bits = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int {
            return bits >= 10
        }
        return false
    }

    static func colorProperties(_ format: CMFormatDescription?) -> [String: Any]? {
        guard let format,
              let p = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
              let t = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
              let m = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        else { return nil }
        return [AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m]
    }

    static func metadata(of asset: AVAsset) async -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        var seen = Set<String>()
        var collected = (try? await asset.load(.metadata)) ?? []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for f in formats { collected += (try? await asset.loadMetadata(for: f)) ?? [] }
        }
        for item in collected {
            guard let id = item.identifier?.rawValue, item.dataType != nil,
                  let value = try? await item.load(.value), seen.insert(id).inserted else { continue }
            let m = AVMutableMetadataItem()
            m.identifier = item.identifier
            m.dataType = item.dataType
            m.value = value
            m.extendedLanguageTag = item.extendedLanguageTag
            items.append(m)
        }
        return items
    }
}

/// Holds the caller's progress closure and drops it when the run ends, so late queue callbacks
/// can never keep it alive past `withoutActuallyEscaping`.
private final class ProgressBox: @unchecked Sendable {
    private let fn = OSAllocatedUnfairLock<(@Sendable (Double) -> Void)?>(initialState: nil)
    init(_ fn: @escaping @Sendable (Double) -> Void) { self.fn.withLock { $0 = fn } }
    func send(_ v: Double) { fn.withLock { $0 }?(v) }
    func close() { fn.withLock { $0 = nil } }
}

/// One reader-output → writer-input pair; only touched on the run's serial queue.
final class Pump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let isVideo: Bool
    var continuation: CheckedContinuation<Void, Never>?
    var finished = false
    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, isVideo: Bool) {
        self.output = output; self.input = input; self.isVideo = isVideo
    }
    func finish(markInput: Bool) {
        guard !finished else { return }
        finished = true
        if markInput { input.markAsFinished() }
        continuation?.resume()
        continuation = nil
    }
}

final class Run: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let pumps: [Pump]
    let queue: DispatchQueue
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { cancelFlag.withLock { $0 } }

    init(reader: AVAssetReader, writer: AVAssetWriter, pumps: [Pump], queue: DispatchQueue) {
        self.reader = reader; self.writer = writer; self.pumps = pumps; self.queue = queue
    }

    func cancel() {
        cancelFlag.withLock { $0 = true }
        queue.async { for p in self.pumps { p.finish(markInput: false) } }
    }

    func pump(_ p: Pump, onPTS: @escaping @Sendable (Double) -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if p.finished || self.isCancelled { p.finished = true; cont.resume(); return }
                p.continuation = cont
                p.input.requestMediaDataWhenReady(on: self.queue) {
                    while !p.finished, p.input.isReadyForMoreMediaData {
                        if self.isCancelled { p.finish(markInput: false); return }
                        guard let sample = p.output.copyNextSampleBuffer() else {
                            p.finish(markInput: true); return
                        }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if !p.input.append(sample) {
                            // Writer failed; abort all pumps so the caller can inspect writer.error.
                            for other in self.pumps { other.finish(markInput: false) }
                            return
                        }
                        onPTS(pts)
                    }
                }
            }
        }
    }
}
