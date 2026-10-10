import Foundation
import PareCore
import PareEngine
import PareLibrary
import PareTranscode
import Testing

@Suite("Pipeline happy path and skips")
struct PipelineBasicTests {
    @Test func compressesImportsAndAwaitsApproval() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        let copy = try #require(e.newID)
        #expect(rig.library.has(copy))
        #expect(rig.library.has(v.id))
        #expect(rig.library.deleteCalls.isEmpty)
        #expect(rig.workspace.isEmptyOfJobs)
        #expect(e.encodedBytes == 40_000_000)
        await p.shutdown()
    }

    @Test func removalDeletesOnlyAfterVerificationAndRecordsRemoved() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await rig.run([v])
        let r = await p.removeOriginals([v.id])
        #expect(r.removed == [v.id])
        #expect(!rig.library.has(v.id))
        #expect(await rig.entry(v.id)?.state == .removed)
        #expect(rig.library.liveCopies(of: v.id).count == 1)
        await p.shutdown()
    }

    @Test func savingsBelowFifteenPercentAreSkippedWithoutImport() async throws {
        let rig = try Rig()
        rig.encoder.ratio = 0.9
        let v = makeVideo(1)
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .skipped)
        #expect(rig.library.importCount == 0)
        #expect(rig.workspace.isEmptyOfJobs)
        await p.shutdown()
    }

    @Test func ineligibleVideosAreSkippedBeforeDownloading() async throws {
        let rig = try Rig()
        var short = makeVideo(1); short.duration = 1
        let p = try await rig.run([short])
        #expect(await rig.entry(short.id)?.state == .skipped)
        #expect(rig.library.exportCount == 0)
        await p.shutdown()
    }

    @Test func videoGoneFromLibraryIsSkipped() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = rig.pipeline()
        try await p.enqueue([v], preset: .balanced)   // never added to the library
        await p.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .skipped)
        await p.shutdown()
    }

    @Test func originalModifiedMidJobIsSkippedAndKept() async throws {
        let rig = try Rig()
        rig.library.modifyOnExport = true
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .skipped)
        #expect(rig.library.importCount == 0)
        #expect(rig.library.has(v.id))
        #expect(rig.workspace.isEmptyOfJobs)
        await p.shutdown()
    }

    @Test func modifiedBetweenCompressAndRemovalIsRefused() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await rig.run([v])
        rig.library.modify(v.id)
        let r = await p.removeOriginals([v.id])
        #expect(r.removed.isEmpty)
        #expect(r.refused[v.id] != nil)
        #expect(rig.library.deleteCalls.isEmpty)
        #expect(rig.library.has(v.id))
        await p.shutdown()
    }

    @Test func accessDeniedFailsAsNeedsUser() async throws {
        let rig = try Rig()
        rig.library.authorizationValue = .denied
        let v = makeVideo(1)
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .failed)
        #expect(e.lastError?.kind == ErrorClass.needsUser.rawValue)
        await p.shutdown()
    }

    @Test func reEnqueueingFinishedJobsDoesNothingButSkippedOnesRestart() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await rig.run([v])
        try await p.enqueue([v], preset: .balanced)
        await p.waitUntilIdle()
        #expect(rig.library.importCount == 1)

        rig.encoder.ratio = 0.9
        let w = makeVideo(2)
        rig.library.add(w)
        try await p.enqueue([w], preset: .balanced)
        await p.waitUntilIdle()
        #expect(await rig.entry(w.id)?.state == .skipped)
        rig.encoder.ratio = 0.4
        try await p.enqueue([w], preset: .balanced)
        await p.waitUntilIdle()
        #expect(await rig.entry(w.id)?.state == .awaitingRemovalApproval)
        await p.shutdown()
    }
}

@Suite("Pipeline resilience: downloading")
struct PipelineDownloadTests {
    @Test func offlineWaitsAndResumesWithoutCountingAnAttempt() async throws {
        let rig = try Rig()
        var v = makeVideo(1); v.isLocal = false
        rig.network.set(.offline)
        let net = rig.network
        rig.clock.onSleep = { n in if n == 4 { net.set(.online) } }
        let p = rig.pipeline()
        let log = EventLog.collect(p)
        rig.library.add(v)
        try await p.enqueue([v], preset: .balanced)
        await p.waitUntilIdle()
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        #expect(e.attempts["download"] == nil)
        #expect(rig.library.exportCount == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.events.contains(.waiting(v.id, .network)))
        #expect(log.events.contains(.resumed(v.id)))
        await p.shutdown()
    }

    @Test func networkDropMidDownloadWaitsThenRetries() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.exportErrors = [URLError(.notConnectedToInternet)]
        rig.network.set(.offline)
        let net = rig.network
        rig.clock.onSleep = { n in if n == 3 { net.set(.online) } }
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        #expect(rig.library.exportCount == 2)
        #expect(e.attempts["download"] == nil)
        await p.shutdown()
    }

    @Test func expensiveNetworkWaitsForWiFiWhenCellularIsOff() async throws {
        let rig = try Rig()
        rig.config.allowExpensiveNetwork = false
        var v = makeVideo(1); v.isLocal = false
        rig.network.set(NetworkStatus(isConnected: true, isExpensive: true))
        let net = rig.network
        rig.clock.onSleep = { n in if n == 2 { net.set(.online) } }
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(rig.clock.sleepCount >= 2)
        await p.shutdown()
    }

    @Test func transientErrorsRetryWithJitteredBackoffUpToTheCap() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.exportErrors = [URLError(.timedOut), URLError(.networkConnectionLost)]
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        #expect(e.attempts["download"] == 2)
        let sleeps = rig.clock.sleeps
        #expect(sleeps.count == 2)
        #expect(sleeps[0] <= 2 && sleeps[1] <= 4)
        await p.shutdown()
    }

    @Test func exhaustingTheRetryBudgetFailsTheJobButNeverCorruptsState() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.exportErrors = Array(repeating: URLError(.timedOut), count: 10)
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .failed)
        #expect(rig.library.has(v.id))
        #expect(rig.workspace.isEmptyOfJobs)
        // The user can retry once the cause is gone.
        rig.library.exportErrors = []
        try await p.retry(v.id)
        await p.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        await p.shutdown()
    }

    @Test func diskFullWaitsForSpaceThenContinues() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.exportErrors = [NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
        rig.disk.set(1_000)
        let disk = rig.disk
        rig.clock.onSleep = { n in if n == 3 { disk.set(500_000_000_000) } }
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        #expect(rig.clock.sleepCount >= 3)
        await p.shutdown()
    }

    @Test func lowDiskBeforeStartWaitsInsteadOfFailing() async throws {
        let rig = try Rig()
        rig.disk.set(10)
        let disk = rig.disk
        rig.clock.onSleep = { n in if n == 2 { disk.set(500_000_000_000) } }
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        await p.shutdown()
    }

    @Test func corruptDownloadIsRetried() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.exportErrors = []
        final class Probe: VideoEncoding, @unchecked Sendable {
            let inner: FakeEncoder; let lock = NSLock(); var bad = 1
            init(_ e: FakeEncoder) { inner = e }
            func takeBad() -> Bool { lock.lock(); defer { lock.unlock() }; if bad > 0 { bad -= 1; return true }; return false }
            func probe(_ url: URL) async -> SourceProbe? {
                if takeBad() { return nil }
                return await inner.probe(url)
            }
            func encode(source: URL, output: URL, settings: EncodeSettings, rung: EncodeRung, progress: @Sendable (Double) -> Void) async throws {
                try await inner.encode(source: source, output: output, settings: settings, rung: rung, progress: progress)
            }
            func verify(source: URL, encoded: URL, settings: EncodeSettings, preset: VideoPreset) async throws -> EncodeVerification {
                try await inner.verify(source: source, encoded: encoded, settings: settings, preset: preset)
            }
        }
        rig.library.add(v)
        let p = VideoPipeline(library: rig.library, journal: rig.journal(), workspace: rig.workspace,
                              encoder: Probe(rig.encoder), network: rig.network, disk: rig.disk, device: rig.device,
                              clock: rig.clock, config: rig.config)
        try await p.enqueue([v], preset: .balanced)
        await p.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(rig.library.exportCount == 2)
        await p.shutdown()
    }
}

@Suite("Pipeline resilience: encoding")
struct PipelineEncodeTests {
    @Test func permanentEncoderFailureFallsDownTheLadder() async throws {
        let rig = try Rig()
        rig.encoder.encodeScript = [TranscodeError.cannotConfigure("quality hint")]
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(Array(rig.encoder.encodeRungs.prefix(2)) == [.preset, .bitrateOnly])
        await p.shutdown()
    }

    @Test func transientEncoderFailureRetriesTheRungTwiceBeforeFallingBack() async throws {
        let rig = try Rig()
        let boom = TranscodeError.writerFailed("x")
        rig.encoder.encodeScript = [boom, boom]
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(Array(rig.encoder.encodeRungs.prefix(3)) == [.preset, .preset, .bitrateOnly])
        await p.shutdown()
    }

    @Test func failedVerificationMovesToTheNextRungAndDiscardsTheOutput() async throws {
        let rig = try Rig()
        rig.encoder.verifyFailures = [true]
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(Array(rig.encoder.encodeRungs.prefix(2)) == [.preset, .bitrateOnly])
        #expect(rig.library.importCount == 1)
        await p.shutdown()
    }

    @Test func everyRungFailingFailsPermanentlyAndKeepsTheOriginal() async throws {
        let rig = try Rig()
        rig.encoder.verifyFailures = Array(repeating: true, count: 10)
        let v = makeVideo(1)
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .failed)
        #expect(e.lastError?.kind == ErrorClass.permanent.rawValue)
        #expect(rig.library.importCount == 0)
        #expect(rig.library.has(v.id))
        await p.shutdown()
    }

    @Test func stalledEncodeIsCancelledAndRetried() async throws {
        let rig = try Rig()
        rig.config.encodeStall = .milliseconds(150)
        rig.encoder.hangFirstEncodes = 1
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(Array(rig.encoder.encodeRungs.prefix(2)) == [.preset, .preset])
        await p.shutdown()
    }

    @Test func stalledDownloadIsCancelledAndRetried() async throws {
        let rig = try Rig()
        rig.config.downloadStall = .milliseconds(150)
        rig.library.exportDelay = .seconds(30)
        let lib = rig.library
        rig.clock.onSleep = { _ in lib.exportDelay = nil }
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(rig.library.exportCount == 2)
        await p.shutdown()
    }

    @Test func thermalPressureAndLowPowerModePauseEncodingNotFailIt() async throws {
        let rig = try Rig()
        rig.device.set(thermal: .serious, lowPower: true)
        let dev = rig.device
        rig.clock.onSleep = { n in
            if n == 2 { dev.set(thermal: .nominal) }
            if n == 4 { dev.set(lowPower: false) }
        }
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(rig.clock.sleepCount >= 4)
        await p.shutdown()
    }
}

@Suite("Pipeline resilience: import")
struct PipelineImportTests {
    @Test func transientImportErrorRetriesAndYieldsOneCopy() async throws {
        let rig = try Rig()
        rig.library.importErrorsBefore = [PhotosErrorCodes.error(PhotosErrorCodes.operationInterrupted)]
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(rig.library.liveCopies(of: v.id).count == 1)
        await p.shutdown()
    }

    @Test func importThatCommittedButReportedFailureIsAdoptedNotDuplicated() async throws {
        let rig = try Rig()
        rig.library.importErrorsAfterCommit = [PhotosErrorCodes.error(PhotosErrorCodes.operationInterrupted)]
        let v = makeVideo(1)
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        #expect(rig.library.liveCopies(of: v.id).count == 1)
        #expect(rig.library.createdCopies[v.id]?.count == 1)
        #expect(e.newID == rig.library.liveCopies(of: v.id).first)
        await p.shutdown()
    }

    @Test func copyThatVanishesAfterImportIsReimportedOnce() async throws {
        let rig = try Rig()
        rig.library.vanishNextImport = true
        let v = makeVideo(1)
        let p = try await rig.run([v])
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        #expect(rig.library.liveCopies(of: v.id).count == 1)
        #expect(rig.library.createdCopies[v.id]?.count == 2)
        await p.shutdown()
    }

    @Test func otherJobsCopiesAreNeverAdopted() async throws {
        let rig = try Rig()
        // Two videos with identical metadata except for the id: each must get its own copy.
        var a = makeVideo(1), b = makeVideo(2)
        b.creationDate = a.creationDate; a.modificationDate = baseDate; b.modificationDate = baseDate
        let p = try await rig.run([a, b])
        let ea = try #require(await rig.entry(a.id)), eb = try #require(await rig.entry(b.id))
        #expect(ea.state == .awaitingRemovalApproval && eb.state == .awaitingRemovalApproval)
        #expect(ea.newID != eb.newID)
        await p.shutdown()
    }
}

@Suite("Pipeline resilience: removal")
struct PipelineRemovalTests {
    func awaiting(_ rig: Rig, _ items: [MediaItem]) async throws -> VideoPipeline {
        try await rig.run(items)
    }

    @Test func userDecliningThePromptKeepsEverythingAndIsNotAnError() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await awaiting(rig, [v])
        rig.library.deleteScripts = [.userCancels]
        let r = await p.removeOriginals([v.id])
        #expect(r.declined == [v.id] && r.removed.isEmpty && r.failed.isEmpty)
        #expect(rig.library.has(v.id))
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        #expect(e.lastError == nil)
        // Approving later works.
        let again = await p.removeOriginals([v.id])
        #expect(again.removed == [v.id])
        await p.shutdown()
    }

    @Test func partialDeleteSettlesEachOriginalFromRealLibraryState() async throws {
        let rig = try Rig()
        let a = makeVideo(1), b = makeVideo(2)
        let p = try await awaiting(rig, [a, b])
        rig.library.deleteScripts = [.deletesFirstThenFails(count: 1, PhotosErrorCodes.error(PhotosErrorCodes.operationInterrupted))]
        let r = await p.removeOriginals([a.id, b.id])
        #expect(r.removed == [a.id])
        #expect(r.failed[b.id] != nil)
        #expect(!rig.library.has(a.id) && rig.library.has(b.id))
        #expect(await rig.entry(a.id)?.state == .removed)
        #expect(await rig.entry(b.id)?.state == .awaitingRemovalApproval)
        let again = await p.removeOriginals([b.id])
        #expect(again.removed == [b.id])
        await p.shutdown()
    }

    @Test func errorAfterEverythingWasActuallyDeletedStillCountsAsRemoved() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await awaiting(rig, [v])
        rig.library.deleteScripts = [.deletesButReportsFailure(NSError(domain: "x", code: 1))]
        let r = await p.removeOriginals([v.id])
        #expect(r.removed == [v.id])
        #expect(await rig.entry(v.id)?.state == .removed)
        await p.shutdown()
    }

    @Test func plainDeleteFailureLeavesTheOriginalAwaiting() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await awaiting(rig, [v])
        rig.library.deleteScripts = [.failsWithoutDeleting(NSError(domain: "x", code: 1))]
        let r = await p.removeOriginals([v.id])
        #expect(r.failed[v.id] != nil)
        #expect(rig.library.has(v.id))
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        await p.shutdown()
    }

    @Test func originalAlreadyDeletedByTheUserIsMarkedRemovedWithoutADeleteCall() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await awaiting(rig, [v])
        rig.library.remove(v.id)
        let r = await p.removeOriginals([v.id])
        #expect(r.removed == [v.id])
        #expect(rig.library.deleteCalls.isEmpty)
        #expect(await rig.entry(v.id)?.state == .removed)
        await p.shutdown()
    }

    @Test func missingNewCopyKeepsTheOriginalAndRedoesTheJob() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await awaiting(rig, [v])
        let copy = try #require(await rig.entry(v.id)?.newID)
        rig.library.remove(copy)
        let r = await p.removeOriginals([v.id])
        #expect(r.removed.isEmpty && r.refused[v.id] != nil)
        #expect(rig.library.deleteCalls.isEmpty)
        #expect(rig.library.has(v.id))
        await p.waitUntilIdle()
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .awaitingRemovalApproval)
        #expect(e.newID != copy)
        #expect(rig.library.liveCopies(of: v.id).count == 1)
        await p.shutdown()
    }

    @Test func copyWithWrongDurationBlocksRemoval() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await awaiting(rig, [v])
        let copy = try #require(await rig.entry(v.id)?.newID)
        var broken = try #require(rig.library.snapshot()[copy]); broken.duration = 5
        rig.library.add(broken)
        let r = await p.removeOriginals([v.id])
        #expect(r.refused[v.id] != nil)
        #expect(rig.library.deleteCalls.isEmpty)
        await p.shutdown()
    }

    @Test func copyWithUnknownSizeBlocksRemoval() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await awaiting(rig, [v])
        let copy = try #require(await rig.entry(v.id)?.newID)
        var broken = try #require(rig.library.snapshot()[copy]); broken.byteSize = nil
        rig.library.add(broken)
        let r = await p.removeOriginals([v.id])
        #expect(r.refused[v.id] != nil)
        #expect(rig.library.deleteCalls.isEmpty)
        await p.shutdown()
    }

    @Test func neverRemovesAnOriginalThatIsNotVerified() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.add(v)
        let journal = rig.journal()
        for state in [OperationJournal.State.planned, .downloading, .encoded, .verified, .importing, .imported, .skipped, .failed] {
            try await journal.update(v.id) { $0.state = state; $0.newID = MediaID("copy-x") }
            let p = rig.pipeline()
            let r = await p.removeOriginals([v.id])
            #expect(r.removed.isEmpty, "state \(state)")
            #expect(r.refused[v.id] != nil, "state \(state)")
            await p.shutdown()
        }
        #expect(rig.library.deleteCalls.isEmpty)
        // Awaiting without a recorded copy is refused too.
        try await journal.update(v.id) { $0.state = .awaitingRemovalApproval; $0.newID = nil }
        let p = rig.pipeline()
        #expect((await p.removeOriginals([v.id])).refused[v.id] != nil)
        #expect(rig.library.deleteCalls.isEmpty)
        await p.shutdown()
    }

    @Test func batchesAreCappedAndEachBatchIsAuditedBeforeDeletion() async throws {
        let rig = try Rig()
        rig.config.removalBatchSize = 2
        let items = (1...5).map { makeVideo($0) }
        let p = try await awaiting(rig, items)
        let r = await p.removeOriginals(items.map(\.id))
        #expect(Set(r.removed) == Set(items.map(\.id)))
        #expect(rig.library.deleteCalls.map(\.count) == [2, 2, 1])
        await p.shutdown()
    }
}

@Suite("Pipeline control")
struct PipelineControlTests {
    @Test func pauseInterruptsWithoutLosingStateAndResumeFinishes() async throws {
        let rig = try Rig()
        rig.network.set(.offline)
        var v = makeVideo(1); v.isLocal = false
        rig.library.add(v)
        let p = rig.pipeline()
        try await p.enqueue([v], preset: .balanced)
        while rig.clock.sleepCount < 3 { await Task.yield() }
        await p.pause()
        await p.waitUntilIdle()
        let mid = try #require(await rig.entry(v.id))
        #expect(mid.state == .downloading)
        rig.network.set(.online)
        await p.resume()
        await p.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        await p.shutdown()
    }

    @Test func cancelStopsAJobCleansUpAndLeavesTheOriginal() async throws {
        let rig = try Rig()
        rig.network.set(.offline)
        var v = makeVideo(1); v.isLocal = false
        rig.library.add(v)
        let p = rig.pipeline()
        try await p.enqueue([v], preset: .balanced)
        while rig.clock.sleepCount < 2 { await Task.yield() }
        await p.cancel(v.id)
        await p.waitUntilIdle()
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .failed && e.lastError?.kind == ErrorClass.cancelled.rawValue)
        #expect(rig.library.has(v.id))
        #expect(rig.workspace.isEmptyOfJobs)
        await p.shutdown()
    }

    @Test func jobsRunOneAtATimeInOrderAndTheStreamReportsIdle() async throws {
        let rig = try Rig()
        let items = (1...3).map { makeVideo($0) }
        for i in items { rig.library.add(i) }
        let p = rig.pipeline()
        let log = EventLog.collect(p)
        try await p.enqueue(items, preset: .balanced)
        await p.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        let finished = log.events.compactMap { e -> MediaID? in
            if case .finished(let id, .awaitingRemovalApproval) = e { return id } else { return nil }
        }
        #expect(finished == items.map(\.id))
        #expect(log.events.last == .idle)
        await p.shutdown()
    }

    @Test func secondPipelineOnTheSameWorkspaceIsLockedOut() async throws {
        let rig = try Rig()
        let a = rig.pipeline(), b = rig.pipeline()
        try await a.recover(autoResume: false)
        await #expect(throws: PipelineError.workspaceLocked) { try await b.recover(autoResume: false) }
        await a.shutdown()
        try await b.recover(autoResume: false)
        await b.shutdown()
    }
}

@Suite("Pipeline resilience: favorites, overlap and held jobs")
struct PipelineSafetyTests {
    @Test func favoriteVideoIsSkippedAtPreflight() async throws {
        let rig = try Rig()
        var v = makeVideo(1)
        v.isFavorite = true
        let p = try await rig.run([v])
        let e = try #require(await rig.entry(v.id))
        #expect(e.state == .skipped)
        #expect(e.lastError?.message == "Favorite, so it was left alone")
        #expect(rig.library.importCount == 0)
        await p.shutdown()
    }

    @Test func originalFavoritedAfterCompressionIsNeverRemoved() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await rig.run([v])
        var fav = try #require(try await rig.library.item(v.id))
        fav.isFavorite = true
        rig.library.add(fav)
        let r = await p.removeOriginals([v.id])
        #expect(r.removed.isEmpty)
        #expect(r.refused[v.id] != nil)
        #expect(rig.library.deleteCalls.isEmpty)
        #expect(rig.library.has(v.id))
        await p.shutdown()
    }

    @Test func concurrentRemovalsDeleteEachOriginalOnce() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        let p = try await rig.run([v])
        rig.library.beforeDelete = { _ in try? await Task.sleep(for: .milliseconds(150)) }
        async let first = p.removeOriginals([v.id])
        async let second = p.removeOriginals([v.id])
        let results = await [first, second]
        #expect(results.flatMap(\.removed) == [v.id])
        #expect(rig.library.deleteCalls == [[v.id]])
        #expect(results.contains { $0.refused[v.id] != nil })
        #expect(await rig.entry(v.id)?.state == .removed)
        // The guard is released afterwards: a later call is judged on the journal, not turned away as overlapping.
        let again = await p.removeOriginals([v.id])
        #expect(again.removed.isEmpty)
        #expect(rig.library.deleteCalls == [[v.id]])
        await p.shutdown()
    }

    @Test func heldJobsDoNotRunUntilReleased() async throws {
        let rig = try Rig()
        let v = makeVideo(1)
        rig.library.add(v)
        let first = rig.pipeline()
        try await first.enqueue([v], preset: .balanced)
        await first.pause()
        await first.shutdown()
        #expect(await rig.entry(v.id)?.state != .awaitingRemovalApproval)

        let p = rig.pipeline()
        try await p.recover(autoResume: false)
        await p.hold([v.id])
        await p.resume()
        await p.waitUntilIdle()
        #expect(rig.library.importCount == 0)
        await p.release([v.id])
        await p.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        await p.shutdown()
    }
}

@Suite("Pipeline resilience: Wi‑Fi only")
struct WiFiOnlyTests {
    @Test func waitsForWiFiWithoutDownloadingOverCellularOrLowDataMode() async throws {
        for status in [NetworkStatus(isConnected: true, isExpensive: true),
                       NetworkStatus(isConnected: true, isConstrained: true)] {
            let rig = try Rig()
            rig.config.allowExpensiveNetwork = false
            var v = makeVideo(1); v.isLocal = false
            rig.network.set(status)
            let (net, lib) = (rig.network, rig.library)
            nonisolated(unsafe) var exportsWhileWaiting = -1
            rig.clock.onSleep = { n in
                if n == 3 { exportsWhileWaiting = lib.exportCount; net.set(.online) }
            }
            let p = rig.pipeline()
            let log = EventLog.collect(p)
            lib.add(v)
            try await p.enqueue([v], preset: .balanced)
            await p.waitUntilIdle()
            #expect(exportsWhileWaiting == 0)
            #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
            #expect(await rig.entry(v.id)?.attempts["download"] == nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(log.events.contains(.waiting(v.id, .expensiveNetwork)))
            #expect(log.events.contains(.resumed(v.id)))
            await p.shutdown()
        }
    }

    @Test func turningCellularOnReleasesAWaitingDownload() async throws {
        let rig = try Rig()
        rig.config.allowExpensiveNetwork = false
        var v = makeVideo(1); v.isLocal = false
        rig.network.set(NetworkStatus(isConnected: true, isExpensive: true))
        let p = rig.pipeline()
        rig.clock.onSleep = { n in if n == 2 { Task { await p.setAllowExpensiveNetwork(true) } } }
        rig.library.add(v)
        try await p.enqueue([v], preset: .balanced)
        await p.waitUntilIdle()
        #expect(await rig.entry(v.id)?.state == .awaitingRemovalApproval)
        await p.shutdown()
    }

    @Test func localVideosNeverWaitForWiFi() async throws {
        let rig = try Rig()
        rig.config.allowExpensiveNetwork = false
        rig.network.set(NetworkStatus(isConnected: true, isExpensive: true))
        let p = try await rig.run([makeVideo(1)])
        #expect(await rig.entry(makeVideo(1).id)?.state == .awaitingRemovalApproval)
        #expect(rig.clock.sleepCount == 0)
        await p.shutdown()
    }
}
