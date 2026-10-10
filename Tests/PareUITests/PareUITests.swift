import CoreGraphics
import Foundation
import ImageIO
import PareCore
import PareLibrary
import Testing
import UniformTypeIdentifiers
@testable import PareUI

private func writeJPEG(_ image: CGImage, to url: URL) throws {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

private func makeFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pare-ui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor private func sampleModel() throws -> (AppModel, URL) {
    let support = try makeFolder()
    return (AppModel(library: SampleLibrary(), supportDirectory: support), support)
}

@Suite struct ScanEngineTests {
    @Test func findsExactAndNearIdenticalGroups() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = SampleLibrary.render(seed: 5, brightness: 0, screenshot: false, width: 400, height: 300)
        try writeJPEG(base, to: dir.appendingPathComponent("a.jpg"))
        try FileManager.default.copyItem(at: dir.appendingPathComponent("a.jpg"), to: dir.appendingPathComponent("a-copy.jpg"))
        try writeJPEG(SampleLibrary.render(seed: 5, brightness: 0.05, screenshot: false, width: 400, height: 300),
                      to: dir.appendingPathComponent("b.jpg"))
        try writeJPEG(SampleLibrary.render(seed: 33, brightness: 0, screenshot: false, width: 400, height: 300),
                      to: dir.appendingPathComponent("c.jpg"))

        let cache = dir.appendingPathComponent("cache/signals.json")
        let engine = ScanEngine(library: FolderLibrary(root: dir), cacheURL: cache)
        let result = try await engine.scan { _ in }
        #expect(result.items.count == 4)
        let group = try #require(result.groups.first { $0.members.contains(MediaID("a.jpg")) })
        #expect(group.members.contains(MediaID("a-copy.jpg")))
        #expect(!group.members.contains(MediaID("c.jpg")))
        #expect(FileManager.default.fileExists(atPath: cache.path))

        // Second run is served from the cache and gives the same grouping.
        let again = try await engine.scan { _ in }
        #expect(again.groups.count == result.groups.count)
    }

    @Test func cancellationThrows() async throws {
        let engine = ScanEngine(library: SampleLibrary())
        let task = Task { try await engine.scan { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite @MainActor struct AppModelTests {
    @Test func approvalFlowProducesSafePlan() async throws {
        let (model, support) = try sampleModel()
        defer { try? FileManager.default.removeItem(at: support) }
        await model.start()
        #expect(model.scanState == .ready)
        #expect(!model.groups.isEmpty)
        #expect(model.plan.isEmpty)   // nothing approved yet

        let g = try #require(model.groups.first)
        model.approveGroup(g.id)
        let approved = try #require(model.group(g.id))
        #expect(!approved.approvedRemovals.isEmpty)
        #expect(!approved.approvedRemovals.contains(approved.suggestedKeeper))
        try SafetyCheck.validate(plan: model.plan, groups: model.groups, items: model.items)

        // The last kept photo can't be unkept, and favorites can't be marked.
        for m in approved.members where model.keepSet(for: approved).contains(m) {
            model.toggleKeep(group: g.id, member: m)
        }
        #expect(!(model.group(g.id).map { model.keepSet(for: $0).isEmpty } ?? true))

        model.skipGroup(g.id)
        #expect(model.group(g.id)?.approvedRemovals.isEmpty == true)
    }

    @Test func favoritesNeverRemovable() async throws {
        let (model, support) = try sampleModel()
        defer { try? FileManager.default.removeItem(at: support) }
        await model.start()
        for g in model.groups { model.approveGroup(g.id) }
        for g in model.groups {
            let g2 = try #require(model.group(g.id))
            for f in g2.favorites { model.toggleKeep(group: g.id, member: f) }
            #expect(g2.favorites.isDisjoint(with: model.plan.removals))
        }
    }

    @Test func launchArgumentsSelectFolder() throws {
        let support = try makeFolder()
        let m = AppModel(arguments: ["app", "--folder", "/some/dir"], environment: [:], supportDirectory: support)
        #expect(m.source == .folder(URL(fileURLWithPath: "/some/dir", isDirectory: true)))
        let e = AppModel(arguments: ["app"], environment: ["PIXELPARE_SAMPLE": "1"], supportDirectory: support)
        #expect(e.source == .sample)
    }

    @Test func sampleFindsBlurryAndLaunchScreen() async throws {
        let support = try makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let model = AppModel(arguments: ["app", "--sample", "--screen", "lighttable"], environment: [:], supportDirectory: support)
        #expect(model.launchScreen == "lighttable")
        await model.start()
        #expect(!model.blurryIDs.isEmpty)
        #expect(model.groups.count >= 3)
        #expect(model.blurryIDs.allSatisfy { model.items[$0]?.isFavorite == false })
        #expect(model.path == [.similar])
        // Blurry photos need explicit selection before they enter a plan.
        #expect(model.plan.isEmpty)
    }
}
