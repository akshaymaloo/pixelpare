import Testing
import Foundation
@testable import PareCore

struct OperationJournalTests {
    @Test func persistsAndReloads() async throws {
        let url = tempJournalURL()
        let j = OperationJournal(url: url)
        try await j.record(original: mid("a"), state: .planned)
        try await j.record(original: mid("a"), state: .imported, newID: mid("a2"))
        let j2 = OperationJournal(url: url)
        let e = await j2.entries()
        #expect(e.count == 1 && e[0].state == .imported && e[0].newID == mid("a2"))
    }

    @Test func recordIsIdempotent() async throws {
        let url = tempJournalURL()
        let j = OperationJournal(url: url)
        try await j.record(original: mid("a"), state: .exported)
        try await j.record(original: mid("a"), state: .exported)
        #expect(await j.entries().count == 1)
    }

    @Test func pendingExcludesRemovedAndFailed() async throws {
        let j = OperationJournal(url: tempJournalURL())
        try await j.record(original: mid("a"), state: .encoded)
        try await j.record(original: mid("b"), state: .removed)
        try await j.record(original: mid("c"), state: .failed, error: "boom")
        #expect(await j.pending().map(\.original) == [mid("a")])
        #expect(await j.entry(for: mid("c"))?.error == "boom")
    }

    @Test func canRemoveOriginalOnlyAfterImportVerified() async throws {
        let j = OperationJournal(url: tempJournalURL())
        for s in [OperationJournal.State.planned, .exported, .encoded, .verified, .imported, .failed, .removed] {
            try await j.record(original: mid("a"), state: s, newID: mid("n"))
            if s == .removed { continue }
            #expect(await j.canRemoveOriginal(mid("a")) == false, "state \(s)")
        }
        let k = OperationJournal(url: tempJournalURL())
        try await k.record(original: mid("a"), state: .importVerified, newID: mid("n"))
        #expect(await k.canRemoveOriginal(mid("a")))
        try await k.record(original: mid("b"), state: .awaitingRemovalApproval, newID: mid("n2"))
        #expect(await k.canRemoveOriginal(mid("b")))
    }

    @Test func cannotRemoveWithoutNewIDOrUnknown() async throws {
        let j = OperationJournal(url: tempJournalURL())
        try await j.record(original: mid("a"), state: .importVerified)
        #expect(await j.canRemoveOriginal(mid("a")) == false)
        #expect(await j.canRemoveOriginal(mid("nope")) == false)
    }

    @Test func removedIsFinal() async throws {
        let j = OperationJournal(url: tempJournalURL())
        try await j.record(original: mid("a"), state: .removed)
        try await j.record(original: mid("a"), state: .planned)
        #expect(await j.entry(for: mid("a"))?.state == .removed)
    }

    @Test func corruptFileIsQuarantinedAndJournalStartsEmpty() async throws {
        let url = tempJournalURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let j = OperationJournal(url: url)
        #expect(await j.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        try await j.record(original: mid("a"), state: .planned)
        #expect(await OperationJournal(url: url).entries().count == 1)
    }

    @Test func noTempFilesLeftBehind() async throws {
        let url = tempJournalURL()
        let j = OperationJournal(url: url)
        try await j.record(original: mid("a"), state: .planned)
        try await j.record(original: mid("a"), state: .exported)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == ["journal.json"])
    }
}

struct CodableRoundTripTests {
    @Test func groupAndApprovalRoundTrip() throws {
        let g = SimilarGroup(members: [mid("a"), mid("b")], suggestedKeeper: mid("a"),
                             reasons: [mid("b"): ["Less sharp"]], kind: .similar, favorites: [mid("a")],
                             approval: .approved(keep: [mid("a")]))
        let back = try JSONDecoder().decode(SimilarGroup.self, from: JSONEncoder().encode(g))
        #expect(back.id == g.id && back.approval == g.approval && back.reasons == g.reasons)
    }

    @Test func mediaItemAndSignalsRoundTrip() throws {
        let v = video("v")
        #expect(try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(v)) == v)
        let s = sig("a", hash: .max, degrees: 33, aes: 0.5)
        let b = try JSONDecoder().decode(ImageSignals.self, from: JSONEncoder().encode(s))
        #expect(b.dHash == .max && b.featurePrint == s.featurePrint)
    }
}
