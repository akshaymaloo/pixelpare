import Foundation
import PareCore
import PareLibrary

extension VideoPipeline {
    /// Deletes originals whose compressed copy is verified. Invariant I1: an original is only ever passed to
    /// `library.delete` after this method re-confirms, right now, that the journal approves it, the original is
    /// unchanged since the job began, and the new copy exists with the expected duration and a known non-zero size.
    public func removeOriginals(_ ids: [MediaID]) async -> RemovalResult {
        var result = RemovalResult()
        var approved: [(id: MediaID, entry: Entry)] = []
        do {
            for id in ids {
                if let ok = try await checkRemovable(id, &result) { approved.append((id, ok)) }
            }
            var index = 0
            while index < approved.count {
                let batch = Array(approved[index..<min(index + config.removalBatchSize, approved.count)])
                index += batch.count
                for b in batch { try await commit(b.id) { $0.state = .removing } }
                let batchIDs = batch.map(\.id)
                do {
                    try await library.delete(batchIDs)
                } catch let error as SimulatedCrash {
                    throw error
                } catch {
                    if ErrorClassifier.classify(error) == .userDeclined {
                        for id in approved[(index - batch.count)...].map(\.id) {
                            try await commit(id) { $0.state = .awaitingRemovalApproval }
                            result.declined.append(id)
                        }
                        return result
                    }
                    // Partial deletes are possible: trust the library, not the error.
                    for id in batchIDs { try await settle(id, error: error, into: &result) }
                    continue
                }
                for id in batchIDs { try await settle(id, error: nil, into: &result) }
            }
        } catch {
            if error is SimulatedCrash { crash() }
        }
        return result
    }

    private func checkRemovable(_ id: MediaID, _ result: inout RemovalResult) async throws -> Entry? {
        guard await journal.canRemoveOriginal(id), let entry = await journal.entry(for: id), let newID = entry.newID else {
            result.refused[id] = "The compressed copy hasn't been verified yet."
            return nil
        }
        let original: MediaItem?
        do { original = try await library.item(id) } catch {
            if error is SimulatedCrash { throw error }
            result.failed[id] = ErrorClassifier.message(for: error)
            return nil
        }
        guard let original else {
            try await commit(id) { $0.state = .removed; $0.lastError = nil }
            workspace.cleanup(for: id)
            result.removed.append(id)
            hub.send(.finished(id, .removed))
            return nil
        }
        guard isUnchanged(original, entry) else {
            result.refused[id] = "The original changed after it was compressed, so it was kept."
            return nil
        }
        let copy: MediaItem?
        do { copy = try await library.item(newID) } catch {
            if error is SimulatedCrash { throw error }
            result.failed[id] = ErrorClassifier.message(for: error)
            return nil
        }
        guard let copy else {
            // The copy is gone: the original must stay, and the job starts over to make a new one.
            try await commit(id) { $0.state = .planned; $0.newID = nil; $0.attempts = [:]; $0.encodeRung = 0 }
            result.refused[id] = "The compressed copy is missing, so the original was kept and will be compressed again."
            if !queue.contains(id) && currentID != id { queue.append(id) }
            kick()
            return nil
        }
        let size = await library.resourceSize(newID) ?? copy.byteSize ?? 0
        let wantDuration = entry.duration ?? original.duration ?? 0
        guard size > 0, wantDuration <= 0 || abs((copy.duration ?? 0) - wantDuration) <= ImportFingerprint.durationTolerance else {
            result.refused[id] = "The compressed copy couldn't be confirmed, so the original was kept."
            return nil
        }
        return entry
    }

    /// After a delete call (successful or not) decide each original's fate from what the library says now.
    private func settle(_ id: MediaID, error: Error?, into result: inout RemovalResult) async throws {
        let still: MediaItem?
        do { still = try await library.item(id) } catch {
            if error is SimulatedCrash { throw error }
            try await commit(id) { $0.state = .awaitingRemovalApproval }
            result.failed[id] = "Couldn't confirm the delete."
            return
        }
        if still == nil {
            try await commit(id) { $0.state = .removed; $0.lastError = nil }
            workspace.cleanup(for: id)
            result.removed.append(id)
            hub.send(.finished(id, .removed))
        } else {
            let message = error.map(ErrorClassifier.message(for:)) ?? "The original is still in your library."
            try await commit(id) {
                $0.state = .awaitingRemovalApproval
                $0.lastError = .init(kind: ErrorClass.transient.rawValue, message: message)
            }
            result.failed[id] = message
        }
    }
}
