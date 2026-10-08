import Testing
import Foundation
@testable import PareCore

struct GrouperTests {
    @Test func exactDuplicatesGroupByHash() {
        let items = [photo("a"), photo("b", at: 500), photo("c", at: 900)]
        let g = Grouper.group(items: items, signals: [:], exactHashes: [mid("a"): "h", mid("b"): "h", mid("c"): "x"])
        #expect(g.count == 1)
        #expect(g[0].kind == .exact)
        #expect(Set(g[0].members) == [mid("a"), mid("b")])
        #expect(g[0].approval == .suggested)
    }

    @Test func exactReasonsSayExactDuplicate() {
        let items = [photo("a"), photo("b", at: 5)]
        let g = Grouper.group(items: items, signals: [:], exactHashes: [mid("a"): "h", mid("b"): "h"])
        let loser = g[0].members.first { $0 != g[0].suggestedKeeper }!
        #expect(g[0].reasons[loser] == ["Exact duplicate"])
    }

    @Test func nearIdenticalIsLibraryWideAcrossTime() {
        let items = [photo("a"), photo("b", at: 86_400 * 200)]
        let s = [sig("a", hash: 0b1111), sig("b", hash: 0b0111, degrees: 90)]
        let g = Grouper.group(items: items, signals: index(s), exactHashes: [:])
        #expect(g.count == 1 && g[0].kind == .nearIdentical)
    }

    @Test func hammingAboveFourIsNotNearIdentical() {
        let items = [photo("a"), photo("b", at: 86_400 * 200)]
        let s = [sig("a", hash: 0), sig("b", hash: 0b11111, degrees: 90)]
        #expect(Grouper.group(items: items, signals: index(s), exactHashes: [:]).isEmpty)
    }

    @Test func similarWithinTimeWindowGroups() {
        let items = [photo("a"), photo("b", at: 60)]
        let s = [sig("a", hash: 0), sig("b", hash: .max, degrees: 10)]
        let g = Grouper.group(items: items, signals: index(s), exactHashes: [:])
        #expect(g.count == 1 && g[0].kind == .similar)
    }

    @Test func similarOutsideTimeWindowDoesNotGroup() {
        let items = [photo("a"), photo("b", at: 120)]
        let s = [sig("a", hash: 0), sig("b", hash: .max, degrees: 10)]
        #expect(Grouper.group(items: items, signals: index(s), exactHashes: [:]).isEmpty)
    }

    @Test func sameBurstGroupsDespiteTimeGap() {
        let items = [photo("a", burst: "B1"), photo("b", at: 600, burst: "B1")]
        let s = [sig("a", hash: 0), sig("b", hash: .max, degrees: 10)]
        #expect(Grouper.group(items: items, signals: index(s), exactHashes: [:]).count == 1)
    }

    @Test func dissimilarFeaturesDoNotGroup() {
        let items = [photo("a"), photo("b", at: 5)]
        let s = [sig("a", hash: 0), sig("b", hash: .max, degrees: 60)]
        #expect(Grouper.group(items: items, signals: index(s), exactHashes: [:]).isEmpty)
    }

    @Test func differentFeaturePrintRevisionsAreNotCompared() {
        let items = [photo("a"), photo("b", at: 5)]
        let s = [sig("a", hash: 0, rev: 1), sig("b", hash: .max, degrees: 1, rev: 2)]
        #expect(Grouper.group(items: items, signals: index(s), exactHashes: [:]).isEmpty)
    }

    @Test func noChainingAcrossRepresentative() {
        // A~B and B~C (≈0.347 each) but A!~C (≈0.68): C must not join A's group.
        let items = [photo("a"), photo("b", at: 10), photo("c", at: 20)]
        let s = [sig("a", hash: 0, degrees: 0), sig("b", hash: 0xFFFF, degrees: 20), sig("c", hash: 0xFFFF_FFFF_FFFF, degrees: 40)]
        let g = Grouper.group(items: items, signals: index(s), exactHashes: [:])
        #expect(g.count == 1)
        #expect(Set(g[0].members) == [mid("a"), mid("b")])
    }

    @Test func eachItemInAtMostOneGroup() {
        let items = (0..<6).map { photo("p\($0)", at: Double($0)) }
        let s = items.map { sig($0.id.raw, hash: 0, degrees: 0) }
        let hashes = Dictionary(uniqueKeysWithValues: items.prefix(2).map { ($0.id, "same") })
        let g = Grouper.group(items: items, signals: index(s), exactHashes: hashes)
        let all = g.flatMap(\.members)
        #expect(all.count == Set(all).count)
    }

    @Test func singletonsAreDropped() {
        let items = [photo("a"), photo("b", at: 5000)]
        let s = [sig("a", hash: 0), sig("b", hash: .max, degrees: 150)]
        #expect(Grouper.group(items: items, signals: index(s), exactHashes: [:]).isEmpty)
    }

    @Test func videosAreIgnored() {
        let items = [video("v1"), video("v2")]
        let g = Grouper.group(items: items, signals: [:], exactHashes: [mid("v1"): "h", mid("v2"): "h"])
        #expect(g.isEmpty)
    }

    @Test func favoritesAreNeverSuggestedForRemoval() {
        let items = [photo("a", fav: true), photo("b", at: 5, fav: true), photo("c", at: 8)]
        let s = [sig("a", sharp: 10), sig("b", sharp: 20, aes: 0.9), sig("c", sharp: 500)]
        let g = Grouper.group(items: items, signals: index(s), exactHashes: [:])
        #expect(g.count == 1)
        #expect(g[0].favorites == [mid("a"), mid("b")])
        #expect(g[0].suggestedRemovals == [mid("c")])
        var approved = g[0]
        approved.approval = .approved(keep: [g[0].suggestedKeeper])
        #expect(approved.approvedRemovals == [mid("c")])
    }

    @Test func groupsOrderedByCreationDate() {
        let items = [photo("late1", at: 10_000), photo("late2", at: 10_005), photo("early1"), photo("early2", at: 5)]
        let s = items.map { sig($0.id.raw, hash: $0.id.raw.hasPrefix("early") ? 0 : .max) }
        let g = Grouper.group(items: items, signals: index(s), exactHashes: [:])
        #expect(g.count == 2)
        #expect(g[0].members.contains(mid("early1")))
    }
}
