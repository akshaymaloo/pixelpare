import Foundation
import PareCore
import PareEngine
import PareLibrary
import PareTranscode
import Testing

@Suite("Pipeline end to end", .serialized, .enabled(if: HardwareEncode.enabled, "Set PIXELPARE_SOFTWARE_ENCODE=1 (or PIXELPARE_HW_ENCODE_TESTS=1) to run encode tests"))
struct EndToEndTests {
    @Test func folderLibraryWithRealTranscoderCompressesImportsAndRemoves() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await Fixtures.make(at: root.appendingPathComponent("clip.mov"), width: 1280, height: 720,
                                seconds: 3, fps: 30, bitrate: 100_000_000)

        let library = FolderLibrary(root: root)
        let items = try await library.items().filter { $0.kind == .video }
        #expect(items.count == 1)
        let original = try #require(items.first)

        let journal = OperationJournal(url: dir.appendingPathComponent("journal.json"))
        let workspace = JobWorkspace(root: dir.appendingPathComponent("Jobs", isDirectory: true))
        var config = PipelineConfig()
        config.minSavings = 0.15
        let pipeline = VideoPipeline(library: library, journal: journal, workspace: workspace, config: config)
        try await pipeline.enqueue([original], preset: .balanced)
        await pipeline.waitUntilIdle()

        let entry = try #require(await journal.entry(for: original.id))
        #expect(entry.state == .awaitingRemovalApproval, "state \(entry.state) \(String(describing: entry.lastError))")
        #expect(workspace.isEmptyOfJobs)
        let afterImport = try await library.items().filter { $0.kind == .video }
        #expect(afterImport.count == 2)
        let newID = try #require(entry.newID)
        let copy = try #require(try await library.item(newID))
        #expect(abs((copy.duration ?? 0) - 3) < 0.3)
        #expect((copy.byteSize ?? .max) < (original.byteSize ?? 0))

        let result = await pipeline.removeOriginals([original.id])
        #expect(result.removed == [original.id])
        let rest = try await library.items().filter { $0.kind == .video }
        #expect(rest.map(\.id) == [newID])
        #expect(await journal.entry(for: original.id)?.state == .removed)
        await pipeline.shutdown()
    }
}
