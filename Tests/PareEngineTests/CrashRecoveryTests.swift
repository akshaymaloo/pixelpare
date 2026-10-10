import Foundation
import PareCore
import PareEngine
import PareLibrary
import Testing

/// Drives a full lifecycle (compress → import → approve removal) and "kills the process" right after the nth
/// journal write by throwing `SimulatedCrash` from the transition hook. A brand-new pipeline over the same journal
/// file, workspace and library then picks up.
enum Lifecycle {
    /// Returns how many journal writes the lifecycle performed, and finishes the work on a fresh pipeline.
    @discardableResult
    static func run(_ rig: Rig, items: [MediaItem], crashAt: Int?) async throws -> Int {
        let counter = Counter()
        let hook: VideoPipeline.TransitionHook = { _ in
            if counter.next() == crashAt { throw SimulatedCrash() }
        }
        for i in items { rig.library.add(i) }
        let first = rig.pipeline(hook: hook)
        do { try await first.enqueue(items, preset: .balanced) } catch is SimulatedCrash {}
        await first.waitUntilIdle()
        _ = await first.removeOriginals(items.map(\.id))
        await first.shutdown()
        let total = counter.value

        // Whatever happened, a fresh process must be able to finish the job.
        for _ in 0..<4 {
            let next = rig.pipeline()
            try await next.recover()
            await next.waitUntilIdle()
            _ = await next.removeOriginals(items.map(\.id))
            await next.waitUntilIdle()
            await next.shutdown()
            let entries = await rig.journal().entries()
            if items.allSatisfy({ id in entries.first { $0.original == id.id }?.state == .removed }) { break }
        }
        return total
    }
}

@Suite("Crash recovery")
struct CrashRecoveryTests {
    @Test func crashingAfterEveryJournalWriteStillEndsWithOneCopyAndTheOriginalRemoved() async throws {
        let dry = try Rig()
        let n = try await Lifecycle.run(dry, items: [makeVideo(1)], crashAt: nil)
        #expect(n >= 10)

        for k in 1...(n + 1) {
            let rig = try Rig()
            let audit = DeleteAudit.install(on: rig)
            let v = makeVideo(1)
            try await Lifecycle.run(rig, items: [v], crashAt: k)
            let e = try #require(await rig.entry(v.id), "crash at \(k)")
            #expect(e.state == .removed, "crash at \(k): \(e.state)")
            #expect(!rig.library.has(v.id), "crash at \(k)")
            #expect(rig.library.liveCopies(of: v.id).count == 1, "crash at \(k)")
            #expect(rig.library.createdCopies[v.id]?.count == 1, "crash at \(k): duplicate import")
            #expect(audit.violations.isEmpty, "crash at \(k): \(audit.violations)")
            #expect(rig.workspace.isEmptyOfJobs, "crash at \(k)")
        }
    }

    @Test func crashBetweenPhotoKitCommitAndJournalWriteAdoptsTheOrphanCopy() async throws {
        let rig = try Rig()
        rig.library.importErrorsAfterCommit = [SimulatedCrash()]
        let v = makeVideo(1)
        rig.library.add(v)
        let first = rig.pipeline()
        try await first.enqueue([v], preset: .balanced)
        await first.waitUntilIdle()
        let mid = try #require(await rig.entry(v.id))
        #expect(mid.state == .importing)
        #expect(mid.newID == nil)
        #expect(rig.library.liveCopies(of: v.id).count == 1)

        let second = rig.pipeline()
        try await second.recover()
        await second.waitUntilIdle()
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        #expect(e.newID == rig.library.liveCopies(of: v.id).first)
        #expect(rig.library.createdCopies[v.id]?.count == 1)
        #expect(rig.library.importCount == 1)
        await second.shutdown()
    }

    @Test func orphanCopyIsAdoptedEvenIfTheOriginalChangedMeanwhile() async throws {
        let rig = try Rig()
        rig.library.importErrorsAfterCommit = [SimulatedCrash()]
        let v = makeVideo(1)
        rig.library.add(v)
        let first = rig.pipeline()
        try await first.enqueue([v], preset: .balanced)
        await first.waitUntilIdle()
        rig.library.modify(v.id)
        let second = rig.pipeline()
        try await second.recover()
        await second.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(rig.library.createdCopies[v.id]?.count == 1)
        // ...but the changed original is never deleted.
        let r = await second.removeOriginals([v.id])
        #expect(r.refused[v.id] != nil && rig.library.has(v.id))
        await second.shutdown()
    }

    @Test func crashAfterDeleteButBeforeTheJournalRecordsRemovalIsReconciled() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let first = try await rig.run([v])
        rig.library.deleteScripts = [.deletesButReportsFailure(SimulatedCrash())]
        _ = await first.removeOriginals([v.id])
        #expect(await rig.entry(v.id)?.state == .removing)
        #expect(!rig.library.has(v.id))
        let second = rig.pipeline()
        try await second.recover(autoResume: false)
        #expect(await rig.entry(v.id)?.state == .removed)
        await second.shutdown()
    }

    @Test func crashBeforeDeleteLeavesTheOriginalAwaitingAfterRecovery() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let first = try await rig.run([v])
        rig.library.deleteScripts = [.failsWithoutDeleting(SimulatedCrash())]
        _ = await first.removeOriginals([v.id])
        #expect(await rig.entry(v.id)?.state == .removing)
        let second = rig.pipeline()
        try await second.recover(autoResume: false)
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(rig.library.has(v.id))
        await second.shutdown()
    }

    @Test(arguments: [OperationJournal.State.downloading, .downloaded, .encoding, .encoded, .verified, .importing, .imported])
    func everyInFlightStateResumesEvenWhenItsFilesAreGone(_ state: OperationJournal.State) async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.add(v)
        let settings = try #require(PresetPolicy.settings(for: v, preset: .balanced))
        try await rig.journal().update(v.id) {
            $0.state = state; $0.preset = .balanced; $0.settings = settings
            $0.originalModificationDate = v.modificationDate; $0.sourceBytes = v.byteSize; $0.duration = 10
            $0.encodedBytes = 40_000_000
            if state == .imported { $0.newID = MediaID("ghost-copy") }
        }
        let p = rig.pipeline()
        try await p.recover()
        await p.waitUntilIdle()
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval, "from \(state): \(e.state) \(e.lastError?.message ?? "")")
        #expect(rig.library.liveCopies(of: v.id).count == 1)
        await p.shutdown()
    }

    @Test func recoveryDeletesOrphanedWorkspacesAndPartialsButKeepsInFlightJobs() async throws {
        let rig = try Rig()
        let fm = FileManager.default
        let stale = rig.workspace.directory(for: MediaID("stale"))
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data([1]).write(to: stale.appendingPathComponent("source.mov"))
        try fm.createDirectory(at: rig.workspace.root, withIntermediateDirectories: true)
        try Data([1]).write(to: rig.workspace.root.appendingPathComponent("stray.partial"))

        let v = makeVideo(1)
        rig.library.add(v)
        let keep = try rig.workspace.prepare(for: v.id)
        try Data([1]).write(to: keep.appendingPathComponent("encoded.mov.partial"))
        try await rig.journal().update(v.id) { $0.state = .downloaded; $0.preset = .balanced }

        let p = rig.pipeline()
        try await p.recover(autoResume: false)
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(!fm.fileExists(atPath: rig.workspace.root.appendingPathComponent("stray.partial").path))
        #expect(fm.fileExists(atPath: keep.path))
        await p.shutdown()
    }

    @Test func autoResumeFalseSettlesButDoesNotRunUntilResume() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.add(v)
        try await rig.journal().update(v.id) { $0.state = .planned; $0.preset = .balanced; $0.originalModificationDate = v.modificationDate }
        let p = rig.pipeline()
        try await p.recover(autoResume: false)
        await p.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .planned)
        await p.resume()
        await p.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        await p.shutdown()
    }
}
