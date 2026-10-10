import CoreGraphics
import Foundation
import PareCore
import PareEngine
import PareLibrary
import Testing

/// In-memory library for Live Photo → still: scriptable creation and delete failures.
final class StillFakeLibrary: MediaLibrary, @unchecked Sendable {
    struct Boom: Error {}
    private let lock = NSLock()
    private var assets: [MediaID: MediaItem] = [:]
    private var counter = 0
    private(set) var createCount = 0
    private(set) var deleteCalls: [[MediaID]] = []
    /// Create the still, then fail: models dying between the PhotoKit commit and the journal write.
    var failAfterCreate = false
    var userDeclinesDelete = false
    var copyDropsFavorite = false
    var copyWidthDelta = 0
    var beforeDelete: (@Sendable (StillFakeLibrary) -> Void)?

    func add(_ item: MediaItem) { lock.withLock { assets[item.id] = item } }
    func modify(_ id: MediaID) { lock.withLock { assets[id]?.modificationDate = Date(timeIntervalSince1970: 9) } }
    func has(_ id: MediaID) -> Bool { lock.withLock { assets[id] != nil } }
    func stills() -> [MediaItem] { lock.withLock { assets.values.filter { $0.kind == .photo } } }
    func allItems() -> [MediaItem] { lock.withLock { Array(assets.values) } }

    func authorization() async -> LibraryAccess { .full }
    func requestAccess() async -> LibraryAccess { .full }
    func items() async throws -> [MediaItem] { allItems() }
    func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage { throw LibraryError.thumbnailFailed }
    func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool, progress: @Sendable (Double) -> Void) async throws -> URL {
        throw LibraryError.exportFailed("n/a")
    }
    func exactHash(_ id: MediaID) async throws -> String? { nil }
    func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID { throw LibraryError.importFailed("n/a") }

    func convertLivePhotoToStill(_ id: MediaID) async throws -> MediaID {
        let (new, fail) = try make(id)
        if fail { throw Boom() }
        return new
    }

    private func make(_ id: MediaID) throws -> (MediaID, Bool) {
        try lock.withLock {
            guard let o = assets[id] else { throw LibraryError.notFound(id.raw) }
            counter += 1; createCount += 1
            let new = MediaID("still-\(counter)")
            assets[new] = MediaItem(id: new, kind: .photo, creationDate: o.creationDate, pixelWidth: o.pixelWidth + copyWidthDelta,
                                    pixelHeight: o.pixelHeight, byteSize: o.byteSize, isFavorite: o.isFavorite && !copyDropsFavorite,
                                    modificationDate: Date())
            let fail = failAfterCreate
            failAfterCreate = false
            return (new, fail)
        }
    }

    func delete(_ ids: [MediaID]) async throws {
        beforeDelete?(self)
        if drop(ids) { throw PhotosErrorCodes.error(PhotosErrorCodes.userCancelled) }
    }

    private func drop(_ ids: [MediaID]) -> Bool {
        lock.withLock {
            deleteCalls.append(ids)
            if userDeclinesDelete { return true }
            for id in ids { assets[id] = nil }
            return false
        }
    }
}

@Suite struct StillConverterTests {
    let created = Date(timeIntervalSince1970: 1_700_000_000)

    func live(_ s: String, fav: Bool = false, edited: Bool = false) -> MediaItem {
        MediaItem(id: MediaID(s), kind: .livePhoto, creationDate: created, pixelWidth: 4032, pixelHeight: 3024,
                  byteSize: 3_000_000, isFavorite: fav, isEdited: edited, modificationDate: Date(timeIntervalSince1970: 5),
                  pairedVideoBytes: 2_500_000)
    }

    func journalURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stills-\(UUID().uuidString)/stills.json")
    }

    func converter(_ lib: StillFakeLibrary, _ url: URL) -> StillConverter {
        StillConverter(library: lib, journal: OperationJournal(url: url))
    }

    @Test func happyPathMakesOneStillThenRemovesOriginal() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1", fav: true)
        lib.add(item)
        // Invariant: the original is only deleted while a matching still exists.
        lib.beforeDelete = { l in #expect(l.stills().count == 1) }
        let r = await converter(lib, url).convert([item])
        #expect(r.converted.count == 1)
        #expect(r.converted[0].savedBytes == 2_500_000)
        #expect(!lib.has(item.id))
        let still = try #require(lib.stills().first)
        #expect(still.isFavorite && still.kind == .photo && still.creationDate == created)
        let entry = await OperationJournal(url: url).entry(for: item.id)
        #expect(entry?.state == .removed && entry?.newID == still.id)
    }

    @Test func crashAfterCreateResumesWithoutDuplicateAndDeletesOriginalOnce() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1")
        lib.add(item)
        lib.failAfterCreate = true
        let first = await converter(lib, url).convert([item])
        #expect(first.failed[item.id] != nil)
        #expect(lib.has(item.id), "the original must survive a failed run")
        #expect(lib.stills().count == 1)
        #expect(lib.deleteCalls.isEmpty)

        // A new process: fresh converter, same journal file. It must adopt the orphaned still.
        let second = await converter(lib, url).convert([item])
        #expect(second.converted.count == 1)
        #expect(lib.createCount == 1, "no duplicate still")
        #expect(lib.stills().count == 1)
        #expect(!lib.has(item.id))
    }

    @Test func declinedDeleteKeepsBothAndRetryReusesTheStill() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1")
        lib.add(item)
        lib.userDeclinesDelete = true
        let first = await converter(lib, url).convert([item])
        #expect(first.declined == [item.id] && first.keptBoth.count == 1 && first.converted.isEmpty)
        #expect(lib.has(item.id))
        let unfinished = await converter(lib, url).unfinished()
        #expect(unfinished.map(\.original) == [item.id])

        lib.userDeclinesDelete = false
        let second = await converter(lib, url).convert([item])
        #expect(second.converted.count == 1)
        #expect(lib.createCount == 1)
        #expect(!lib.has(item.id))
    }

    @Test func stillThatDoesNotMatchNeverLeadsToDeletion() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1")
        lib.add(item)
        lib.copyWidthDelta = 400
        let r = await converter(lib, url).convert([item])
        #expect(r.failed[item.id] != nil && r.converted.isEmpty)
        #expect(lib.deleteCalls.isEmpty && lib.has(item.id))
    }

    @Test func copyThatLostFavoriteKeepsOriginal() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1", fav: true)
        lib.add(item)
        lib.copyDropsFavorite = true
        let r = await converter(lib, url).convert([item])
        #expect(r.failed[item.id] != nil)
        #expect(lib.deleteCalls.isEmpty && lib.has(item.id))
    }

    @Test func originalChangedAfterRunStartedIsKept() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1")
        lib.add(item)
        lib.failAfterCreate = true
        _ = await converter(lib, url).convert([item])
        lib.modify(item.id)   // the user edited it before the retry
        let r = await converter(lib, url).convert([item])
        #expect(r.skipped[item.id] != nil && r.converted.isEmpty)
        #expect(lib.deleteCalls.isEmpty && lib.has(item.id))
    }

    @Test func editedAndPlainPhotosAreSkipped() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let edited = live("E", edited: true)
        let plain = MediaItem(id: MediaID("P"), kind: .photo, creationDate: created, pixelWidth: 10, pixelHeight: 10)
        lib.add(edited); lib.add(plain)
        let r = await converter(lib, url).convert([edited, plain])
        #expect(r.skipped.count == 2 && lib.createCount == 0 && lib.deleteCalls.isEmpty)
    }

    @Test func unrelatedPhotoTakenAMomentLaterIsNotMistakenForTheCopy() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1")
        lib.add(item)
        lib.add(MediaItem(id: MediaID("neighbor"), kind: .photo, creationDate: created.addingTimeInterval(0.4),
                          pixelWidth: 4032, pixelHeight: 3024, byteSize: 3_000_000))
        lib.failAfterCreate = true
        _ = await converter(lib, url).convert([item])
        let r = await converter(lib, url).convert([item])
        #expect(r.converted.count == 1)
        #expect(r.converted[0].copy.raw.hasPrefix("still-"), "the real copy, not the neighbour")
        #expect(lib.has(MediaID("neighbor")))
    }

    @Test func cancellationBeforeStartTouchesNothing() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1")
        lib.add(item)
        let conv = converter(lib, url)
        let task = Task { await conv.convert([item]) }
        task.cancel()
        let r = await task.value
        #expect(r.converted.isEmpty)
        #expect(lib.has(item.id))
    }

    @Test func staleJournalCopyIsRecreatedWhenItVanished() async throws {
        let lib = StillFakeLibrary(), url = journalURL()
        let item = live("L1")
        lib.add(item)
        lib.userDeclinesDelete = true
        let first = await converter(lib, url).convert([item])
        let gone = try #require(first.keptBoth.first).copy
        lib.userDeclinesDelete = false
        await lib.removeAsset(gone)
        let second = await converter(lib, url).convert([item])
        #expect(second.converted.count == 1 && second.converted[0].copy != gone)
        #expect(lib.createCount == 2)
    }
}

extension StillFakeLibrary {
    func removeAsset(_ id: MediaID) async { try? await delete([id]) }
}
