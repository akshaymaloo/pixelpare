import Foundation
import PareCore
import PareLibrary

public struct StillResult: Sendable {
    public struct Converted: Sendable, Equatable {
        public var original: MediaID
        public var copy: MediaID
        public var savedBytes: Int64
    }
    public var converted: [Converted] = []
    /// Copy exists and is verified, but the original is still there (the delete was declined or couldn't be confirmed).
    public var keptBoth: [Converted] = []
    public var skipped: [MediaID: String] = [:]
    public var failed: [MediaID: String] = [:]
    public var declined: [MediaID] = []
    public init() {}
}

/// Turns Live Photos into stills with the same discipline as the video pipeline: every step is journaled, a still that
/// was created but never recorded is found again by fingerprint (never duplicated), and the original is deleted only
/// after the copy is re-confirmed to exist right now.
///
/// Journal states per original: `importing` (an import was started, so a copy may exist), `awaitingRemovalApproval` (copy verified, original
/// still here), `removing` (delete issued), `removed` (final). Uses its own journal file, separate from the video press.
public actor StillConverter {
    private let library: any MediaLibrary
    private let journal: OperationJournal
    private let now: @Sendable () -> Date

    public init(library: any MediaLibrary, journal: OperationJournal, now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library; self.journal = journal; self.now = now
    }

    /// Originals whose conversion didn't finish (crash, quit, declined delete). Running `convert` on them again
    /// reuses the existing copy and only deletes the original.
    public func unfinished() async -> [OperationJournal.Entry] {
        await journal.entries().filter { [.importing, .awaitingRemovalApproval, .removing].contains($0.state) }
    }

    public func convert(_ items: [MediaItem], progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> StillResult {
        var result = StillResult()
        for (i, item) in items.enumerated() {
            if Task.isCancelled { break }
            progress(i, items.count)
            do { try await process(item, &result) } catch is CancellationError { break } catch {
                result.failed[item.id] = ErrorClassifier.message(for: error)
            }
        }
        progress(items.count, items.count)
        return result
    }

    private func process(_ listed: MediaItem, _ result: inout StillResult) async throws {
        let id = listed.id
        let prior = await journal.entry(for: id)
        guard let original = try await library.item(id) else {
            // Gone already: either the delete finished before a crash, or the user removed it.
            if let prior, let copy = prior.newID, try await library.item(copy) != nil {
                try await commit(id) { $0.state = .removed; $0.lastError = nil }
                result.converted.append(.init(original: id, copy: copy, savedBytes: prior.sourceBytes ?? 0))
            } else {
                result.skipped[id] = "It's no longer in your library."
            }
            return
        }
        if prior?.state == .removed { result.skipped[id] = "Already converted."; return }
        guard original.kind == .livePhoto, !original.isEdited else {
            result.skipped[id] = original.isEdited ? "Edited Live Photos are left alone." : "It isn't a Live Photo."
            return
        }
        // Without both dates a copy that was made but never journaled can't be told apart from other photos.
        guard original.creationDate != nil, original.modificationDate != nil else {
            result.skipped[id] = "Its date information is missing, so it was left alone."
            return
        }

        var entry = try await commit(id) { e in
            if e.state == .planned || e.state.isTerminal { e.state = .preflight }
            e.sourceBytes = e.sourceBytes ?? original.pairedVideoBytes
            e.originalModificationDate = e.originalModificationDate ?? original.modificationDate
            e.lastError = nil
        }

        // 0. Fingerprint the original's photo data; it's the only thing that can prove a copy is really ours.
        if entry.sourceDigest == nil {
            guard let digest = try await library.stillResourceDigest(id) else {
                result.failed[id] = "The photo data couldn't be read, so the original was kept."
                return
            }
            entry = try await commit(id) { $0.sourceDigest = digest }
        }
        guard let sourceDigest = entry.sourceDigest else { return }

        // 1. The copy: recorded one, else one a crashed import created, else make it.
        var copy: MediaID? = entry.newID
        if let c = copy, try await library.item(c) == nil {
            copy = nil
            entry = try await commit(id) { $0.newID = nil; $0.state = .importing; $0.copyDigest = nil; $0.copyModificationDate = nil }
        }
        // Only an import that was journaled as started can have left an orphan behind.
        if copy == nil, entry.importToken != nil {
            let others = await journal.importedIDs(excludingJob: id)
            let candidates = try await library.stillCopyCandidates(
                of: original, addedAfter: entry.importStartedAt ?? now(), excluding: others)
            var matching: [MediaID] = []
            for c in candidates where try await library.stillResourceDigest(c) == sourceDigest { matching.append(c) }
            if matching.count > 1 {
                result.failed[id] = "Several photos could be the copy, so nothing was changed."
                return
            }
            copy = matching.first
        }
        if copy == nil {
            try Task.checkCancellation()
            entry = try await commit(id) { e in
                e.state = .importing
                e.importToken = e.importToken ?? UUID().uuidString
                e.importStartedAt = self.now()
            }
            copy = try await library.convertLivePhotoToStill(id)
        }
        guard let newID = copy else { return }
        entry = try await commit(id) { $0.newID = newID; $0.state = .imported }

        // 2. Verify the copy before the original may be touched.
        guard let still = try await library.item(newID) else {
            try await commit(id) { $0.newID = nil; $0.state = .importing }
            result.failed[id] = "The new still couldn't be found, so the original was kept."
            return
        }
        let a = [original.pixelWidth, original.pixelHeight].sorted(), b = [still.pixelWidth, still.pixelHeight].sorted()
        guard still.kind != .livePhoto, still.kind != .video, abs(a[0] - b[0]) <= 2, abs(a[1] - b[1]) <= 2,
              let stillBytes = still.byteSize, stillBytes > 0 else {
            try await commit(id) { $0.lastError = .init(kind: "permanent", message: "The new still didn't match.") }
            result.failed[id] = "The new still didn't match the original, so the original was kept."
            return
        }
        guard still.isFavorite == original.isFavorite else {
            result.failed[id] = "The new still didn't keep the favorite mark, so the original was kept."
            return
        }
        guard let copyDigest = try await library.stillResourceDigest(newID), !still.isEdited,
              entry.copyDigest == nil || entry.copyDigest == copyDigest,
              entry.copyModificationDate == nil || entry.copyModificationDate == still.modificationDate else {
            result.failed[id] = "The still changed since it was verified, so the original was kept."
            return
        }
        entry = try await commit(id) {
            $0.state = .awaitingRemovalApproval; $0.encodedBytes = stillBytes
            $0.copyDigest = copyDigest; $0.copyModificationDate = still.modificationDate
        }
        let saved = entry.sourceBytes ?? 0
        let outcome = StillResult.Converted(original: id, copy: newID, savedBytes: saved)

        // 3. Re-check the original right now, then delete it.
        guard let fresh = try await library.item(id) else {
            try await commit(id) { $0.state = .removed }
            result.converted.append(outcome); return
        }
        guard let was = entry.originalModificationDate, fresh.modificationDate == was, !fresh.isEdited else {
            result.skipped[id] = "It changed after the still was made, so the original was kept."
            result.keptBoth.append(outcome); return
        }
        // The copy must be unchanged right up to the delete.
        guard let stillNow = try await library.item(newID), !stillNow.isEdited,
              stillNow.modificationDate == entry.copyModificationDate,
              try await library.stillResourceDigest(newID) == entry.copyDigest else {
            result.failed[id] = "The still changed, so the original was kept."
            return
        }
        try Task.checkCancellation()
        try await commit(id) { $0.state = .removing }
        var deleteError: Error?
        do { try await library.delete([id]) } catch { deleteError = error }
        if let deleteError, ErrorClassifier.classify(deleteError) == .userDeclined {
            try await commit(id) { $0.state = .awaitingRemovalApproval }
            result.declined.append(id); result.keptBoth.append(outcome); return
        }
        // Partial or failed deletes: trust the library, not the error.
        var gone = false
        do { gone = try await library.item(id) == nil } catch {}
        if gone {
            try await commit(id) { $0.state = .removed; $0.lastError = nil }
            result.converted.append(outcome)
        } else {
            let message = deleteError.map(ErrorClassifier.message(for:)) ?? "The original is still in your library."
            try await commit(id) { $0.state = .awaitingRemovalApproval; $0.lastError = .init(kind: "transient", message: message) }
            result.failed[id] = message
            result.keptBoth.append(outcome)
        }
    }

    @discardableResult
    private func commit(_ id: MediaID, _ change: @Sendable (inout OperationJournal.Entry) -> Void) async throws -> OperationJournal.Entry {
        try await journal.update(id, now: now(), change)
    }
}
