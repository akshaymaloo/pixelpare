import Foundation
import PareCore
import PareLibrary
import PareTranscode

extension VideoPipeline {
    typealias Entry = OperationJournal.Entry

    func step(_ e: Entry) async throws {
        let id = e.original
        switch e.state {
        case .planned:
            try await commit(id) { $0.state = .preflight }
        case .preflight: try await preflight(e)
        case .downloading: try await download(e)
        case .downloaded:
            if sourceFile(id) == nil { try await commit(id) { $0.state = .downloading } }
            else { try await commit(id) { $0.state = .encoding } }
        case .encoding: try await encode(e)
        case .encoded: try await verifyEncoded(e)
        case .verified: try await startImport(e)
        case .importing: try await importCopy(e)
        case .imported: try await verifyImported(e)
        case .awaitingRemovalApproval, .removing, .removed, .skipped, .failed: break
        }
    }

    func sourceFile(_ id: MediaID) -> URL? {
        let url = workspace.sourceURL(for: id)
        return workspace.exists(url) ? url : nil
    }

    func encodedFile(_ id: MediaID) -> URL? {
        let url = workspace.encodedURL(for: id)
        return workspace.exists(url) ? url : nil
    }

    // MARK: Preflight

    func preflight(_ e: Entry) async throws {
        let id = e.original
        let access = await library.authorization()
        if access == .denied || access == .notDetermined { throw LibraryError.accessDenied }
        guard let item = try await library.item(id) else { return try await skip(id, "No longer in your library") }
        if item.isFavorite { return try await skip(id, "Favorite, so it was left alone") }
        // Edit detection (I1) needs a modification date and copy reconciliation (I2) needs a creation date.
        guard item.modificationDate != nil, item.creationDate != nil else {
            return try await skip(id, "Missing date information, so it was left alone")
        }
        if e.originalModificationDate != nil, !isUnchanged(item, e) {
            return try await skip(id, "Changed while waiting, so it was left alone")
        }
        if case .skipped(let reason) = PresetPolicy.eligibility(item) { return try await skip(id, reason.message) }
        guard let preset = e.preset, let settings = PresetPolicy.settings(for: item, preset: preset) else {
            return try await skip(id, "This setting doesn't apply to this video")
        }
        let estimate = PresetPolicy.estimate(item, preset: preset)
        let needed = (item.byteSize ?? 0) + Int64(Double(estimate.high) * 1.3) + config.diskHeadroom
        try await ensureDisk(id, needed: needed)
        try await commit(id) { cur in
            cur.state = .downloading; cur.settings = settings
            cur.sourceBytes = item.byteSize; cur.duration = item.duration
            if cur.originalModificationDate == nil { cur.originalModificationDate = item.modificationDate }
        }
    }

    // MARK: Download

    func download(_ e: Entry) async throws {
        let id = e.original
        guard let item = try await library.item(id) else { return try await skip(id, "No longer in your library") }
        guard isUnchanged(item, e) else { return try await skip(id, "Changed while waiting, so it was left alone") }
        try workspace.prepare(for: id)
        var sourceURL = sourceFile(id)
        if sourceURL == nil {
            try await ensureDisk(id, needed: (item.byteSize ?? 0) + config.diskHeadroom)
            if !item.isLocal {
                let allow = config.allowExpensiveNetwork
                try await waitUntil(id, .network) {
                    let s = network.status()
                    return s.isConnected && (allow || !(s.isExpensive || s.isConstrained))
                }
            }
            let staging = workspace.stagingDirectory(for: id)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let lib = library, hub = self.hub
            let watchdog = StallWatchdog(step: "download", timeout: config.downloadStall, grace: config.stallGrace)
            let exported = try await watchdog.run { touch in
                touch()
                return try await lib.exportVideo(id, to: staging, allowNetwork: true) { p in
                    touch(); hub.send(.progress(id, .download, p))
                }
            }
            guard workspace.exists(exported) else { throw PipelineError.invalidSource("empty file") }
            let final = workspace.finalSourceURL(for: id, ext: exported.pathExtension)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: exported, to: final)
            try? FileManager.default.removeItem(at: staging)
            sourceURL = final
        }
        guard let source = sourceURL else { throw PipelineError.invalidSource("missing") }
        guard let probe = await encoder.probe(source) else {
            try? FileManager.default.removeItem(at: source)
            throw PipelineError.invalidSource("not a readable video")
        }
        let refined = probe.refine(item)
        if case .skipped(let reason) = PresetPolicy.eligibility(refined) { return try await skip(id, reason.message) }
        guard let preset = e.preset, let settings = PresetPolicy.settings(for: refined, preset: preset) else {
            return try await skip(id, "This setting doesn't apply to this video")
        }
        try await commit(id) {
            $0.state = .downloaded; $0.settings = settings; $0.sourceBytes = probe.bytes; $0.duration = probe.duration
        }
    }

    // MARK: Encode

    func encode(_ e: Entry) async throws {
        let id = e.original
        guard let source = sourceFile(id) else { return try await commit(id) { $0.state = .downloading } }
        guard let settings = e.settings else { return try await commit(id) { $0.state = .planned } }
        try await waitUntil(id, .thermal) {
            device.thermalState != .serious && device.thermalState != .critical
        }
        try await waitUntil(id, .lowPower) { !device.isLowPowerModeEnabled }
        try await ensureDisk(id, needed: (e.sourceBytes ?? 0) / 2 + config.diskHeadroom)

        let ladder = encoder.ladder(for: settings)
        guard e.encodeRung < ladder.count else {
            return try await fail(id, .permanent, "This video couldn't be compressed safely.")
        }
        let rung = ladder[e.encodeRung]
        workspace.removePartials(for: id)
        try? FileManager.default.removeItem(at: workspace.encodedURL(for: id))
        let partial = workspace.encodedPartialURL(for: id)
        let enc = encoder, hub = self.hub, preset = e.preset ?? .balanced
        _ = preset
        let watchdog = StallWatchdog(step: "encode", timeout: config.encodeStall, grace: config.stallGrace)
        do {
            try await watchdog.run { touch in
                touch()
                try await enc.encode(source: source, output: partial, settings: settings, rung: rung) { p in
                    touch(); hub.send(.progress(id, .encode, p))
                }
            }
            guard workspace.exists(partial) else { throw PipelineError.invalidSource("empty encode") }
        } catch {
            if error is SimulatedCrash || Task.isCancelled { throw error }
            let cls = ErrorClassifier.classify(error)
            if cls == .waitDisk || cls == .waitNetwork || cls == .cancelled || cls == .needsUser { throw error }
            workspace.removePartials(for: id)
            let rungKey = "encode.\(e.encodeRung)"
            let message = ErrorClassifier.message(for: error)
            let count = try await commitEntry(id) {
                $0.attempts[rungKey] = ($0.attempts[rungKey] ?? 0) + 1
                $0.lastError = .init(kind: cls.rawValue, message: message)
            }.attempts[rungKey] ?? 1
            if cls == .permanent || count >= config.encodeAttemptsPerRung {
                try await commit(id) { $0.encodeRung += 1 }
            } else {
                let delay = config.retryEncode.delay(forAttempt: count, using: &rng)
                hub.send(.retrying(id, .encode, attempt: count, after: delay, reason: ErrorClassifier.message(for: error)))
                try await clock.sleep(for: delay)
            }
            return
        }
        let final = workspace.encodedURL(for: id)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: partial, to: final)
        let size = (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.int64Value ?? 0
        try await commit(id) { $0.state = .encoded; $0.encodedBytes = size }
    }

    // MARK: Verify

    func verifyEncoded(_ e: Entry) async throws {
        let id = e.original
        guard let source = sourceFile(id) else { return try await commit(id) { $0.state = .downloading } }
        guard let encoded = encodedFile(id), let settings = e.settings else {
            return try await commit(id) { $0.state = .encoding }
        }
        let v = try await encoder.verify(source: source, encoded: encoded, settings: settings,
                                         preset: e.preset ?? .balanced)
        if !v.passed {
            let why = v.failures.joined(separator: "; ")
            try? FileManager.default.removeItem(at: encoded)
            return try await commit(id) {
                $0.state = .encoding; $0.encodeRung += 1; $0.encodedBytes = nil
                $0.lastError = .init(kind: "verification", message: why)
            }
        }
        if v.savingsFraction < config.minSavings {
            return try await skip(id, "Wouldn't save enough space to be worth it")
        }
        try await commit(id) {
            $0.state = .verified; $0.encodedBytes = v.encodedBytes; $0.sourceBytes = v.originalBytes
            $0.encodedWidth = v.displayWidth; $0.encodedHeight = v.displayHeight; $0.lastError = nil
        }
    }

    // MARK: Import

    func startImport(_ e: Entry) async throws {
        let id = e.original
        guard encodedFile(id) != nil else {
            let back: OperationJournal.State = sourceFile(id) == nil ? .downloading : .encoding
            return try await commit(id) { $0.state = back }
        }
        let now = clock.now()
        try await commit(id) {
            $0.state = .importing
            if $0.importStartedAt == nil { $0.importToken = UUID().uuidString; $0.importStartedAt = now }
        }
    }

    func importCopy(_ e: Entry) async throws {
        let id = e.original
        // §5: before importing anything, look for a copy that a previous attempt created but never journaled.
        if let found = try await reconcile(e) {
            return try await commit(id) { $0.state = .imported; $0.newID = found }
        }
        guard let item = try await library.item(id) else { return try await skip(id, "No longer in your library") }
        guard isUnchanged(item, e) else { return try await skip(id, "Changed while waiting, so it was left alone") }
        guard let encoded = encodedFile(id) else {
            let back: OperationJournal.State = sourceFile(id) == nil ? .downloading : .encoding
            return try await commit(id) { $0.state = back }
        }
        let newID = try await library.importVideo(encoded, preserving: item)
        try await commit(id) { $0.state = .imported; $0.newID = newID }
    }

    func reconcile(_ e: Entry) async throws -> MediaID? {
        guard let since = e.importStartedAt else { return nil }
        let item = try await library.item(e.original)
        let fp = ImportFingerprint(creationDate: item?.creationDate,
                                   duration: e.duration ?? item?.duration ?? 0,
                                   pixelWidth: e.encodedWidth ?? e.settings?.width ?? 0,
                                   pixelHeight: e.encodedHeight ?? e.settings?.height ?? 0,
                                   byteSize: e.encodedBytes)
        // Never adopt an original (this job's or another's) or another job's copy.
        var excluded = await journal.importedIDs(excludingJob: e.original)
        for other in await journal.entries() { excluded.insert(other.original) }
        return try await library.findImportedCopy(fingerprint: fp, addedAfter: since, excluding: excluded)
    }

    func verifyImported(_ e: Entry) async throws {
        let id = e.original
        guard let newID = e.newID else { return try await commit(id) { $0.state = .importing } }
        var found: MediaItem?
        var attempt = 0
        while found == nil, attempt < config.verifyImported.maxAttempts {
            attempt += 1
            found = try await library.item(newID)
            if found == nil, attempt < config.verifyImported.maxAttempts {
                try await clock.sleep(for: config.verifyImported.delay(forAttempt: attempt, using: &rng))
            }
        }
        guard let copy = found else {
            // The copy vanished: forget it and let reconciliation or a fresh import produce exactly one.
            let redo = try await commitEntry(id) { $0.attempts["reimport"] = ($0.attempts["reimport"] ?? 0) + 1 }
                .attempts["reimport"] ?? 1
            if redo > 3 { return try await fail(id, .transient, "The compressed copy keeps disappearing.") }
            return try await commit(id) { $0.state = .importing; $0.newID = nil }
        }
        let want = e.duration ?? 0
        if want > 0, abs((copy.duration ?? 0) - want) > ImportFingerprint.durationTolerance {
            return try await fail(id, .permanent, "The new copy's length doesn't match the original.")
        }
        if let expected = e.encodedBytes, expected > 0, let size = await library.resourceSize(newID),
           Double(size) < Double(expected) * 0.9 || Double(size) > Double(expected) * 1.1 {
            return try await fail(id, .permanent, "The new copy's size doesn't match what was imported.")
        }
        let saved = max(0, (e.sourceBytes ?? 0) - (e.encodedBytes ?? 0))
        try await commit(id) { $0.state = .awaitingRemovalApproval; $0.lastError = nil }
        workspace.cleanup(for: id)
        hub.send(.finished(id, .awaitingRemovalApproval(newID: newID, savedBytes: saved)))
    }
}
