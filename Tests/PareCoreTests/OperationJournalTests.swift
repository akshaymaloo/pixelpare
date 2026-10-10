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

    private func writeV1(_ json: String) throws -> URL {
        let url = tempJournalURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func migratesV1FileStatesAndKeepsBackup() async throws {
        let url = try writeV1("""
        {"version":1,"entries":[
         {"original":{"raw":"a"},"state":"exported","updatedAt":"2024-01-01T00:00:00Z"},
         {"original":{"raw":"b"},"state":"importVerified","newID":{"raw":"b2"},"updatedAt":"2024-01-01T00:00:00Z"},
         {"original":{"raw":"c"},"state":"failed","error":"boom","updatedAt":"2024-01-01T00:00:00Z"},
         {"original":{"raw":"d"},"state":"mystery","updatedAt":"2024-01-01T00:00:00Z"},
         {"original":{"raw":"e"},"state":"imported","newID":{"raw":"e2"},"updatedAt":"2024-01-01T00:00:00Z"}]}
        """)
        let j = OperationJournal(url: url)
        #expect(await j.entry(for: mid("a"))?.state == .downloaded)
        #expect(await j.entry(for: mid("b"))?.state == .awaitingRemovalApproval)
        #expect(await j.canRemoveOriginal(mid("b")))
        #expect(await j.entry(for: mid("c"))?.state == .failed)
        #expect(await j.entry(for: mid("c"))?.error == "boom")
        #expect(await j.entry(for: mid("d"))?.state == .planned)
        #expect(await j.entry(for: mid("e"))?.state == .imported)
        #expect(await j.entry(for: mid("e"))?.newID == mid("e2"))
        #expect(await j.entry(for: mid("a"))?.attempts == [:])
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("v1").path))

        // The file on disk is now v2 and reloads identically.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"version\" : 2"))
        let again = OperationJournal(url: url)
        #expect(await again.entries() == j.entries())
    }

    @Test func v2RoundTripsAllFields() async throws {
        let url = tempJournalURL()
        let j = OperationJournal(url: url)
        let when = Date(timeIntervalSince1970: 1_700_000_000.25)
        try await j.update(mid("a"), now: when) {
            $0.state = .importing; $0.preset = .balanced
            $0.settings = EncodeSettings(width: 1920, height: 1080, frameRate: 30, quality: 0.6, bitsPerPixel: 0.07)
            $0.importToken = "tok"; $0.importStartedAt = when; $0.attempts = ["import": 2]
            $0.lastError = .init(kind: "transient", message: "x"); $0.nextRetryAt = when
            $0.sourceBytes = 10; $0.encodedBytes = 5; $0.originalModificationDate = when; $0.encodeRung = 1
        }
        let back = await OperationJournal(url: url).entry(for: mid("a"))
        #expect(back == (await j.entry(for: mid("a"))))
        #expect(back?.importStartedAt == when)
    }

    @Test func unchangedUpdateDoesNotRewrite() async throws {
        let url = tempJournalURL()
        let j = OperationJournal(url: url)
        try await j.update(mid("a")) { $0.state = .encoding }
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(20))
        try await j.update(mid("a")) { $0.state = .encoding }
        let second = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(first == second)
    }

    @Test func removingStateAllowsRemovalDecisionForRecovery() async throws {
        let j = OperationJournal(url: tempJournalURL())
        try await j.update(mid("a")) { $0.state = .removing; $0.newID = mid("n") }
        #expect(await j.canRemoveOriginal(mid("a")))
        #expect(await j.pending().count == 1)
        try await j.update(mid("b")) { $0.state = .skipped }
        #expect(await j.pending().map(\.original) == [mid("a")])
    }

    @Test func importedIDsExcludeOwnJob() async throws {
        let j = OperationJournal(url: tempJournalURL())
        try await j.update(mid("a")) { $0.newID = mid("a2") }
        try await j.update(mid("b")) { $0.newID = mid("b2") }
        #expect(await j.importedIDs(excludingJob: mid("a")) == [mid("b2")])
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
