import AVFoundation
import Foundation
import PareCore
import PareEngine
import PareLibrary
import PareTranscode
import Testing

/// Runs the real pipeline (export → encode → verify → import → approve → remove) over phone-like clips for every
/// preset. Clips come from `scripts/make-test-videos.sh`:
///
///     scripts/make-test-videos.sh
///     PIXELPARE_SOFTWARE_ENCODE=1 PIXELPARE_TEST_VIDEOS=.scratch/videos swift test --no-parallel \\
///         --filter pipelineCompressesPhoneLikeClips
///
/// Set `PIXELPARE_TEST_OUTPUT=<dir>` to keep the copies, then run `scripts/score-test-videos.sh` for SSIM.
@Suite(.serialized, .enabled(if: HardwareEncode.enabled && RealClips.dir != nil,
                             "Set PIXELPARE_TEST_VIDEOS=<dir> and PIXELPARE_SOFTWARE_ENCODE=1 to run"))
struct RealClipsTests {
    @Test(arguments: VideoPreset.allCases)
    func pipelineCompressesPhoneLikeClips(preset: VideoPreset) async throws {
        let source = try #require(RealClips.dir)
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clips = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "mov" && !$0.lastPathComponent.hasPrefix(".") }
        try #require(!clips.isEmpty, "no .mov clips in \(source.path)")
        for clip in clips {
            try FileManager.default.copyItem(at: clip, to: root.appendingPathComponent(clip.lastPathComponent))
        }

        let library = FolderLibrary(root: root)
        let originals = try await library.items().filter { $0.kind == .video }
        let journal = OperationJournal(url: dir.appendingPathComponent("journal.json"))
        let workspace = JobWorkspace(root: dir.appendingPathComponent("Jobs", isDirectory: true))
        let pipeline = VideoPipeline(library: library, journal: journal, workspace: workspace, config: PipelineConfig())
        let started = Date()
        try await pipeline.enqueue(originals, preset: preset)
        await pipeline.waitUntilIdle()
        let elapsed = Date().timeIntervalSince(started)

        var rows = ["preset \(preset.rawValue) — \(String(format: "%.1f", elapsed)) s"]
        var approved: [MediaID] = []
        for original in originals.sorted(by: { $0.id.raw < $1.id.raw }) {
            let entry = try #require(await journal.entry(for: original.id))
            let name = original.id.raw
            switch entry.state {
            case .awaitingRemovalApproval:
                let newID = try #require(entry.newID)
                let copy = try #require(try await library.item(newID))
                let before = original.byteSize ?? 0, after = copy.byteSize ?? 0
                #expect(after < before, "\(name) didn't shrink")
                #expect(abs((copy.duration ?? 0) - (original.duration ?? 0)) < 0.3, "\(name) duration changed")
                #expect((copy.pixelWidth > copy.pixelHeight) == (original.pixelWidth > original.pixelHeight),
                        "\(name) orientation changed")
                let origAudio = try await RealClips.hasAudio(root.appendingPathComponent(original.id.raw))
                let copyAudio = try await RealClips.hasAudio(root.appendingPathComponent(copy.id.raw))
                #expect(origAudio == copyAudio, "\(name) audio track lost")
                #expect(copy.videoCodec?.lowercased().hasPrefix("hvc") == true || copy.videoCodec == "hevc",
                        "\(name) copy codec \(copy.videoCodec ?? "nil")")
                if let keep = RealClips.outputDir {
                    try? FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
                    let dest = keep.appendingPathComponent("\(preset.rawValue)-\(name)")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: root.appendingPathComponent(copy.id.raw), to: dest)
                }
                approved.append(original.id)
                rows.append(String(format: "  %-34@ %4d×%-4d %6.1f MB → %4d×%-4d %6.1f MB  saves %4.1f%%",
                                   name as NSString, original.pixelWidth, original.pixelHeight, Double(before) / 1e6,
                                   copy.pixelWidth, copy.pixelHeight, Double(after) / 1e6,
                                   100 * (1 - Double(after) / Double(max(before, 1)))))
            case .skipped:
                rows.append("  \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) skipped: \(entry.error ?? "?")")
            default:
                Issue.record("\(name) ended in \(entry.state): \(entry.error ?? "-")")
                rows.append("  \(name) \(entry.state) \(entry.error ?? "")")
            }
        }
        print(rows.joined(separator: "\n"))
        #expect(workspace.isEmptyOfJobs)

        let result = await pipeline.removeOriginals(approved)
        #expect(Set(result.removed) == Set(approved))
        for id in approved { #expect(try await library.item(id) == nil) }
        await pipeline.shutdown()
    }
}

enum RealClips {
    static let dir: URL? = ProcessInfo.processInfo.environment["PIXELPARE_TEST_VIDEOS"].map {
        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }

    /// Optional: keep each copy as `<preset>-<clip>` here, e.g. to score quality with ffmpeg's SSIM filter.
    static let outputDir: URL? = ProcessInfo.processInfo.environment["PIXELPARE_TEST_OUTPUT"].map {
        URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
    }

    static func hasAudio(_ url: URL) async throws -> Bool {
        try await !AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty
    }
}
