import Foundation
import PareCore
import PareEngine
import PareLibrary
import PareTranscode
import Testing

/// Seeded chaos: random faults in every layer plus random process deaths, then the invariants of
/// docs/resilience.md §7 are checked on the final state.
@Suite("Randomized fault injection")
struct FaultInjectionTests {
    static let runs = 300

    @Test func threeHundredSeededRunsKeepEveryInvariant() async throws {
        var rested = 0
        var removedTotal = 0, skippedTotal = 0, failedTotal = 0
        for seed in 0..<Self.runs {
            let outcome = try await Self.runSeed(UInt64(seed))
            rested += 1
            removedTotal += outcome.removed; skippedTotal += outcome.skipped; failedTotal += outcome.failed
        }
        #expect(rested == Self.runs)
        // The faults are survivable by design: most jobs must complete, not merely "not corrupt anything".
        #expect(removedTotal > Self.runs)
        print("fault injection: removed \(removedTotal), skipped \(skippedTotal), failed \(failedTotal)")
    }

    struct Outcome { var removed = 0, skipped = 0, failed = 0 }

    static func pick<T>(_ options: [T], count: ClosedRange<Int>, _ g: inout SplitMix64) -> [T] {
        (0..<Int.random(in: count, using: &g)).map { _ in options[Int.random(in: 0..<options.count, using: &g)] }
    }

    static func runSeed(_ seed: UInt64) async throws -> Outcome {
        var g = SplitMix64(seed: seed)
        let rig = try Rig()
        rig.seed = seed
        let audit = DeleteAudit.install(on: rig)
        let lib = rig.library

        let count = Int.random(in: 1...3, using: &g)
        let items = (1...count).map { n -> MediaItem in
            var v = makeVideo(n)
            v.isLocal = Int.random(in: 0..<3, using: &g) != 0
            return v
        }
        for i in items { lib.add(i) }

        let ph = PhotosErrorCodes.self
        lib.exportErrors = pick([URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.networkConnectionLost),
                                 NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), LibraryError.exportFailed("x")] as [Error],
                                count: 0...3, &g)
        lib.importErrorsBefore = pick([ph.error(ph.operationInterrupted), URLError(.timedOut)] as [Error], count: 0...2, &g)
        lib.importErrorsAfterCommit = pick([ph.error(ph.operationInterrupted), SimulatedCrash()] as [Error], count: 0...1, &g)
        lib.itemErrors = pick([URLError(.timedOut)] as [Error], count: 0...2, &g)
        lib.vanishNextImport = Int.random(in: 0..<6, using: &g) == 0
        lib.modifyOnExport = Int.random(in: 0..<10, using: &g) == 0
        lib.deleteScripts = pick([
            .userCancels,
            .failsWithoutDeleting(NSError(domain: "x", code: 1)),
            .deletesFirstThenFails(count: 1, NSError(domain: "x", code: 2)),
            .deletesButReportsFailure(NSError(domain: "x", code: 3)),
            .failsWithoutDeleting(SimulatedCrash()),
            .deletesButReportsFailure(SimulatedCrash()),
        ] as [FakeLibrary.DeleteScript], count: 0...3, &g)
        rig.encoder.encodeScript = pick([nil, TranscodeError.writerFailed("w"), TranscodeError.cannotConfigure("c")] as [Error?],
                                        count: 0...3, &g)
        rig.encoder.verifyFailures = pick([true, false], count: 0...2, &g)
        rig.encoder.ratio = Int.random(in: 0..<10, using: &g) == 0 ? 0.9 : 0.4

        if Int.random(in: 0..<3, using: &g) == 0 {
            rig.network.set(.offline); rig.disk.set(100); rig.device.set(thermal: .serious, lowPower: true)
            let (net, disk, dev) = (rig.network, rig.disk, rig.device)
            let at = Int.random(in: 1...6, using: &g)
            rig.clock.onSleep = { n in
                if n == at { net.set(.online); disk.set(500_000_000_000); dev.set(thermal: .nominal, lowPower: false) }
            }
        }

        let crashPoints = Set(pick(Array(1...45), count: 0...3, &g))
        let counter = Counter()
        let hook: VideoPipeline.TransitionHook = { _ in
            if crashPoints.contains(counter.next()) { throw SimulatedCrash() }
        }

        var enqueued = false
        var converged = false
        let ids = items.map(\.id)
        for _ in 0..<30 {
            let p = rig.pipeline(hook: hook)
            do { try await p.recover() } catch is SimulatedCrash {} catch { Issue.record("seed \(seed): recover \(error)") }
            if !enqueued {
                do { try await p.enqueue(items, preset: .balanced); enqueued = true } catch is SimulatedCrash {} catch {
                    Issue.record("seed \(seed): enqueue \(error)")
                }
            }
            await p.waitUntilIdle()
            _ = await p.removeOriginals(ids)
            await p.waitUntilIdle()
            await p.shutdown()
            let entries = await rig.journal().entries()
            if enqueued, ids.allSatisfy({ id in
                guard let s = entries.first(where: { $0.original == id })?.state else { return false }
                return s == .removed || s == .skipped || s == .failed
            }) { converged = true; break }
        }
        let fin = rig.pipeline()
        try await fin.recover(autoResume: false)
        await fin.shutdown()

        // I4: convergence in a bounded number of steps.
        #expect(converged, "seed \(seed): did not converge")
        #expect(counter.value < 900, "seed \(seed): \(counter.value) journal writes")
        // I1: nothing was deleted without the full pre-delete checks.
        #expect(audit.violations.isEmpty, "seed \(seed): \(audit.violations)")

        let entries = await rig.journal().entries()
        var out = Outcome()
        var created = 0
        for item in items {
            let e = entries.first { $0.original == item.id }
            let live = lib.liveCopies(of: item.id)
            created += lib.createdCopies[item.id]?.count ?? 0
            // I2: never more than one live copy per original.
            #expect(live.count <= 1, "seed \(seed) \(item.id.raw): \(live.count) live copies")
            // I1/I3: the original is gone exactly when the journal says removed, and then the copy is there.
            let gone = !lib.has(item.id)
            #expect(gone == (e?.state == .removed), "seed \(seed) \(item.id.raw): gone=\(gone) state=\(String(describing: e?.state))")
            if e?.state == .removed { #expect(live.count == 1 && live.first == e?.newID, "seed \(seed): removed without its copy") }
            if e?.state == .skipped { #expect(live.isEmpty || lib.importCount > 0, "seed \(seed)") }
            switch e?.state {
            case .removed: out.removed += 1
            case .skipped: out.skipped += 1
            default: out.failed += 1
            }
        }
        #expect(created <= count + 1, "seed \(seed): \(created) copies created for \(count) videos")
        #expect(!entries.contains { $0.state == .removing }, "seed \(seed): stuck in removing")
        // I5: no scratch files remain once every job is at rest.
        #expect(rig.workspace.isEmptyOfJobs, "seed \(seed): workspace not clean")
        return out
    }
}
