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

/// Forwards to a SampleLibrary with scripted favorites and delete behaviour.
final class ScriptedLibrary: MediaLibrary, @unchecked Sendable {
    enum DeleteMode: Sendable { case normal, deletesOnlyFirst, deletesNothingAndThrows }
    let base = SampleLibrary()
    private let lock = NSLock()
    private var _favorites: Set<MediaID> = []
    private var _mode = DeleteMode.normal
    private var _deleteCalls: [[MediaID]] = []
    var favorites: Set<MediaID> { get { lock.withLock { _favorites } } set { lock.withLock { _favorites = newValue } } }
    var mode: DeleteMode { get { lock.withLock { _mode } } set { lock.withLock { _mode = newValue } } }
    var deleteCalls: [[MediaID]] { lock.withLock { _deleteCalls } }

    func authorization() async -> LibraryAccess { .full }
    func requestAccess() async -> LibraryAccess { .full }
    func items() async throws -> [MediaItem] {
        let fav = favorites
        return try await base.items().map { var i = $0; if fav.contains(i.id) { i.isFavorite = true }; return i }
    }
    func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage {
        try await base.thumbnail(id, maxPixel: maxPixel, allowNetwork: allowNetwork)
    }
    func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool, progress: @Sendable (Double) -> Void) async throws -> URL {
        try await base.exportVideo(id, to: dir, allowNetwork: allowNetwork, progress: progress)
    }
    func exactHash(_ id: MediaID) async throws -> String? { try await base.exactHash(id) }
    func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID {
        try await base.importVideo(file, preserving: original)
    }
    func delete(_ ids: [MediaID]) async throws {
        lock.withLock { _deleteCalls.append(ids) }
        switch mode {
        case .normal: try await base.delete(ids)
        case .deletesOnlyFirst:
            try await base.delete(Array(ids.prefix(1)))
            throw LibraryError.exportFailed("Simulated partial failure")
        case .deletesNothingAndThrows: throw LibraryError.exportFailed("Simulated failure")
        }
    }
}

@Suite @MainActor struct KeeperAndRemovalTests {
    func ready(_ lib: any MediaLibrary = SampleLibrary()) async throws -> (AppModel, URL) {
        let support = try makeFolder()
        let model = AppModel(library: lib, supportDirectory: support)
        await model.start()
        return (model, support)
    }

    func plainGroup(_ m: AppModel) throws -> SimilarGroup {
        try #require(m.groups.first { $0.favorites.isEmpty && $0.members.count >= 3 })
    }

    @Test func keeperCannotBeMarked() async throws {
        let (m, support) = try await ready()
        defer { try? FileManager.default.removeItem(at: support) }
        let g = try plainGroup(m)
        let keeper = m.keeper(for: g)
        m.toggleKeep(group: g.id, member: keeper)
        #expect(m.keepSet(for: m.group(g.id)!).contains(keeper))
        let other = try #require(g.members.first { $0 != keeper })
        m.toggleKeep(group: g.id, member: other)   // now kept
        m.toggleKeep(group: g.id, member: other)   // marked again
        #expect(!m.keepSet(for: m.group(g.id)!).contains(other))
        m.approveGroup(g.id)
        #expect(m.group(g.id)?.approvedRemovals.contains(keeper) == false)
        try SafetyCheck.validate(plan: m.plan, groups: m.groups, items: m.items)
    }

    @Test func makingAnotherKeeperSwapsRolesAndKeepsTheOldOneUnmarked() async throws {
        let (m, support) = try await ready()
        defer { try? FileManager.default.removeItem(at: support) }
        let g = try plainGroup(m)
        let old = m.keeper(for: g)
        let new = try #require(g.members.first { $0 != old })
        m.setKeeper(group: g.id, member: new)
        let g2 = try #require(m.group(g.id))
        #expect(m.keeper(for: g2) == new)
        #expect(m.keepSet(for: g2).isSuperset(of: [old, new]))
        m.toggleKeep(group: g.id, member: new)   // keeper: ignored
        #expect(m.keepSet(for: g2).contains(new))
        m.toggleKeep(group: g.id, member: old)   // the old keeper can now be marked
        #expect(!m.keepSet(for: m.group(g.id)!).contains(old))
        #expect(m.keepSet(for: m.group(g.id)!).contains(new))
    }

    @Test func changingAnApprovedGroupWithdrawsApproval() async throws {
        let (m, support) = try await ready()
        defer { try? FileManager.default.removeItem(at: support) }
        let g = try plainGroup(m)
        m.approveGroup(g.id)
        #expect(m.approvedGroupCount == 1)
        let removable = try #require(m.group(g.id)?.approvedRemovals.first)
        m.toggleKeep(group: g.id, member: removable)   // un-mark: changes the removal set
        #expect(m.group(g.id)?.approval == .suggested)
        #expect(m.plan.removals.isEmpty)

        m.approveGroup(g.id)
        let target = try #require(m.group(g.id)?.approvedRemovals.first)
        m.setKeeper(group: g.id, member: target)   // a marked photo becomes keeper: removals change
        #expect(m.group(g.id)?.approval == .suggested)
        #expect(!m.plan.removals.contains(target))
    }

    @Test func photoThatBecameFavoriteIsNotDeleted() async throws {
        let lib = ScriptedLibrary()
        let (m, support) = try await ready(lib)
        defer { try? FileManager.default.removeItem(at: support) }
        let g = try plainGroup(m)
        m.approveGroup(g.id)
        let victims = try #require(m.group(g.id)?.approvedRemovals)
        let saved = try #require(victims.sorted().first)
        lib.favorites = [saved]
        m.executePlan()
        try await waitForDone(m)
        #expect(lib.deleteCalls.flatMap { $0 }.contains(saved) == false)
        guard case .done(let s) = m.stage else { Issue.record("not done"); return }
        #expect(s.removedCount == victims.count - 1)
        #expect(s.notes.contains { $0.contains("favorite") })
    }

    @Test func partialDeleteReportsOnlyConfirmedRemovals() async throws {
        let lib = ScriptedLibrary()
        lib.mode = .deletesOnlyFirst
        let (m, support) = try await ready(lib)
        defer { try? FileManager.default.removeItem(at: support) }
        let g = try plainGroup(m)
        m.approveGroup(g.id)
        let n = try #require(m.group(g.id)?.approvedRemovals.count)
        #expect(n >= 2)
        m.executePlan()
        try await waitForDone(m)
        guard case .done(let s) = m.stage else { Issue.record("not done"); return }
        #expect(s.removedCount == 1)
        #expect(s.notes.contains { $0.contains("Removed 1 of \(n)") })
    }

    @Test func failedDeleteConfirmsNothingRemoved() async throws {
        let lib = ScriptedLibrary()
        lib.mode = .deletesNothingAndThrows
        let (m, support) = try await ready(lib)
        defer { try? FileManager.default.removeItem(at: support) }
        let g = try plainGroup(m)
        m.approveGroup(g.id)
        m.executePlan()
        try await waitForDone(m)
        guard case .done(let s) = m.stage else { Issue.record("not done"); return }
        #expect(s.removedCount == 0 && s.removedBytes == 0)
        #expect(s.notes.contains { $0.contains("weren't removed") })
    }

    func waitForDone(_ m: AppModel) async throws {
        for _ in 0..<200 {
            if case .done = m.stage { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("run never finished")
    }

    @Test func recoveredJobsStayHeldUntilAcceptedAndDiscardCancels() async throws {
        let support = try makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let a = MediaID("Beach day.mov"), b = MediaID("Road trip.mov"), c = MediaID("Concert.mov")
        let seed = OperationJournal(url: support.appendingPathComponent("journal-sample.json"))
        for id in [a, b, c] { try await seed.record(original: id, state: .planned) }
        let m = AppModel(library: SampleLibrary(), supportDirectory: support)
        await m.start()
        #expect(Set(m.recoveredJobs.map(\.original)) == [a, b, c])
        #expect(m.plan.isEmpty && !m.canExecute)

        await m.discardRecovered(c)
        #expect(m.recoveredJobs.map(\.original).contains(c) == false)
        m.setRecoveredAccepted(a, true)
        #expect(m.canExecute)

        m.executePlan()
        try await waitForDone(m)
        let journal = OperationJournal(url: support.appendingPathComponent("journal-sample.json"))
        #expect(await journal.entry(for: c)?.state == .failed)       // discarded
        #expect(await journal.entry(for: a)?.state != .planned)      // accepted: it ran (and was skipped: no preset)
        #expect(await journal.entry(for: b)?.state == .planned)      // never accepted: untouched
        #expect(m.recoveredJobs.map(\.original) == [b])
    }

    @Test func overlappingRemovalCallsRunOnceAndUpdateTheirOwnRun() async throws {
        let support = try makeFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        let id = MediaID("Beach day.mov")
        let seed = OperationJournal(url: support.appendingPathComponent("journal-sample.json"))
        try await seed.record(original: id, state: .awaitingRemovalApproval, newID: MediaID("missing-copy"))
        let m = AppModel(library: SampleLibrary(), supportDirectory: support)
        await m.start()
        m.reviewPendingOriginals()
        guard case .done(let before) = m.stage else { Issue.record("no recap"); return }
        async let r1: Void = m.removeVideoOriginals()
        async let r2: Void = m.removeVideoOriginals()
        _ = await (r1, r2)
        #expect(!m.isRemoving)
        guard case .done(let after) = m.stage else { Issue.record("no recap"); return }
        #expect(after.id == before.id)
        #expect(after.notes.filter { $0.contains("kept") }.count == 1)
    }
}

@Suite @MainActor struct SourceIdentityTests {
    @Test func foldersGetDistinctStableKeys() {
        let a = AppModel.folderKey(URL(fileURLWithPath: "/tmp/pare-a", isDirectory: true))
        let b = AppModel.folderKey(URL(fileURLWithPath: "/tmp/pare-b", isDirectory: true))
        #expect(a != b)
        #expect(a == AppModel.folderKey(URL(fileURLWithPath: "/tmp/pare-a/../pare-a", isDirectory: true)))
        #expect(a.count == 16)
    }

    @Test func cacheEntryIsInvalidatedByModificationDate() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        var item = MediaItem(id: MediaID("x"), kind: .photo, creationDate: day, pixelWidth: 10, pixelHeight: 10,
                             byteSize: 100, modificationDate: day)
        var cache = SignalCache(revision: 1)
        cache.entries["x"] = .init(byteSize: 100, modificationDate: day, exactHash: "h", signals: nil)
        #expect(cache.entry(for: item) != nil)
        item.modificationDate = day.addingTimeInterval(5)
        #expect(cache.entry(for: item) == nil)
    }
}
