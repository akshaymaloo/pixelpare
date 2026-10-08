import Testing
import Foundation
@testable import PareCore

struct KeeperRankerTests {
    @Test func prefersFavorite() {
        let items = index([photo("a", fav: true), photo("b", at: 1)])
        let sigs = index([sig("a", sharp: 1), sig("b", sharp: 1000)])
        #expect(KeeperRanker.rank([mid("a"), mid("b")], items: items, signals: sigs).keeper == mid("a"))
    }

    @Test func prefersSharperAndExplainsWhy() {
        let items = index([photo("a"), photo("b", at: 1)])
        let sigs = index([sig("a", sharp: 50), sig("b", sharp: 200)])
        let r = KeeperRanker.rank([mid("a"), mid("b")], items: items, signals: sigs)
        #expect(r.keeper == mid("b"))
        #expect(r.reasons[mid("a")]?.contains("Less sharp") == true)
    }

    @Test func faceQualityReason() {
        let items = index([photo("a"), photo("b", at: 1)])
        let sigs = index([sig("a", face: 0.9), sig("b", face: 0.3)])
        let r = KeeperRanker.rank([mid("a"), mid("b")], items: items, signals: sigs)
        #expect(r.keeper == mid("a"))
        #expect(r.reasons[mid("b")]?.contains("Eyes/face less clear") == true)
    }

    @Test func tieFallsToResolutionThenReason() {
        let items = index([photo("a", w: 2000, h: 1500), photo("b", at: 1, w: 4000, h: 3000)])
        let sigs = index([sig("a"), sig("b")])
        let r = KeeperRanker.rank([mid("a"), mid("b")], items: items, signals: sigs)
        #expect(r.keeper == mid("b"))
        #expect(r.reasons[mid("a")] == ["Lower resolution"])
    }

    @Test func fullTieKeepsEarliest() {
        let items = index([photo("late", at: 50), photo("early", at: 0)])
        let sigs = index([sig("late"), sig("early")])
        #expect(KeeperRanker.rank([mid("late"), mid("early")], items: items, signals: sigs).keeper == mid("early"))
    }

    @Test func favoritesGetNoRemovalReasons() {
        let items = index([photo("a", fav: true), photo("b", at: 1, fav: true), photo("c", at: 2)])
        let r = KeeperRanker.rank([mid("a"), mid("b"), mid("c")], items: items, signals: [:])
        #expect(r.reasons.keys.contains(mid("c")))
        #expect(r.reasons.count == 1)
    }

    @Test func worksWithoutSignals() {
        let items = index([photo("a", w: 100, h: 100), photo("b", at: 1, w: 200, h: 200)])
        #expect(KeeperRanker.rank([mid("a"), mid("b")], items: items, signals: [:]).keeper == mid("b"))
    }
}
