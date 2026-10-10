import Testing
import Foundation
@testable import PareCore

struct TrayRuleTests {
    let now = t0.addingTimeInterval(200 * 86_400)

    func recording(_ s: String, ageDays: Double, size: Int64? = 100_000_000, fav: Bool = false) -> MediaItem {
        MediaItem(id: mid(s), kind: .video, creationDate: now.addingTimeInterval(-ageDays * 86_400), pixelWidth: 1179,
                  pixelHeight: 2556, byteSize: size, isFavorite: fav, duration: 60, isScreenRecording: true)
    }

    // MARK: Screen recordings

    @Test func recordingsOldBiggestFirstNoFavoritesNoPlainVideos() {
        let plain = MediaItem(id: mid("plain"), kind: .video, creationDate: now.addingTimeInterval(-90 * 86_400),
                              pixelWidth: 1920, pixelHeight: 1080, byteSize: 900_000_000, duration: 10)
        let items = [recording("small", ageDays: 40, size: 10), recording("big", ageDays: 60, size: 500),
                     recording("fresh", ageDays: 5), recording("fav", ageDays: 90, fav: true),
                     recording("unknown", ageDays: 50, size: nil), plain]
        let ids = ScreenRecordingRule.candidates(items, olderThan: 30, now: now)
        #expect(ids == [mid("big"), mid("small"), mid("unknown")])
    }

    // MARK: Biggest

    @Test func biggestRanksBySizeIncludesFavoritesExcludesUnknownSmallAndLeftovers() {
        var leftover = photo("left", size: 80_000_000); leftover.burstPick = false
        let items = [photo("p1", size: 30_000_000), video("v1", size: 2_000_000_000), photo("tiny", size: 2_000_000),
                     photo("unknown", size: nil), photo("fav", fav: true, size: 40_000_000), leftover]
        #expect(BiggestRule.candidates(items) == [mid("v1"), mid("fav"), mid("p1")])
        #expect(BiggestRule.candidates(items, limit: 1) == [mid("v1")])
    }

    // MARK: Bursts

    func frame(_ s: String, burst: String = "b", pick: Bool?, fav: Bool = false, size: Int64 = 3_000_000) -> MediaItem {
        var i = photo(s, fav: fav, burst: burst, size: size); i.burstPick = pick; return i
    }

    @Test func burstOffersUnpickedNonFavoriteFramesAndKeepsPicks() {
        let g = BurstRule.groups([frame("pick", pick: true), frame("x1", pick: false), frame("x2", pick: false),
                                  frame("fav", pick: false, fav: true), photo("lone")])
        #expect(g.count == 1)
        #expect(g[0].picks == [mid("pick")])
        #expect(g[0].leftovers == [mid("x1"), mid("x2")])
    }

    @Test func burstWithoutPickOrWithoutLeftoversIsNotOffered() {
        #expect(BurstRule.groups([frame("a", pick: false), frame("b", pick: false)]).isEmpty)
        #expect(BurstRule.groups([frame("a", pick: true)]).isEmpty)
        #expect(BurstRule.groups([frame("a", pick: true), frame("f", pick: false, fav: true)]).isEmpty)
    }

    @Test func burstsSortedByReclaimableBytes() {
        let g = BurstRule.groups([frame("p1", burst: "s", pick: true), frame("l1", burst: "s", pick: false, size: 1),
                                  frame("p2", burst: "l", pick: true), frame("l2", burst: "l", pick: false, size: 9)])
        #expect(g.map(\.burstID) == ["l", "s"])
    }

    // MARK: Live Photos

    @Test func livePhotoCandidatesNeedKnownPairedSizeAndNoEdits() {
        func live(_ s: String, paired: Int64?, edited: Bool = false, fav: Bool = false) -> MediaItem {
            var i = photo(s, fav: fav, kind: .livePhoto); i.pairedVideoBytes = paired; i.isEdited = edited; return i
        }
        let ids = LivePhotoRule.candidates([live("a", paired: 2_000_000), live("b", paired: 3_500_000, fav: true),
                                            live("edited", paired: 3_000_000, edited: true), live("unknown", paired: nil),
                                            photo("plain")])
        #expect(ids == [mid("b"), mid("a")])
    }

    // MARK: Plan & safety

    @Test func videoRemovalRequiresExplicitVideoApproval() throws {
        let v = recording("rec", ageDays: 60)
        let items = index([v])
        let plan = CleanupPlan(groups: [], approvedScreenshots: [v.id])
        #expect(throws: SafetyViolation.removalOfVideo(v.id)) {
            try SafetyCheck.validate(plan: plan, groups: [], items: items, explicitlyApproved: [v.id])
        }
        #expect(throws: SafetyViolation.removalOfVideo(v.id)) {
            try SafetyCheck.validate(plan: plan, groups: [], items: items, approvedVideoRemovals: [v.id])
        }
        try SafetyCheck.validate(plan: plan, groups: [], items: items, explicitlyApproved: [v.id], approvedVideoRemovals: [v.id])
    }

    @Test func favoriteVideoNeverRemovedEvenWhenApproved() {
        let v = recording("fav", ageDays: 60, fav: true)
        let plan = CleanupPlan(removals: [v.id])
        #expect(throws: SafetyViolation.removalOfFavorite(v.id)) {
            try SafetyCheck.validate(plan: plan, groups: [], items: index([v]), explicitlyApproved: [v.id], approvedVideoRemovals: [v.id])
        }
    }

    @Test func removedVideoDropsItsCompressionJob() {
        let v = recording("rec", ageDays: 60)
        let plan = CleanupPlan(groups: [], approvedScreenshots: [v.id], videoJobs: [v.id: .gentle])
        #expect(plan.videoJobs.isEmpty)
    }

    @Test func burstLeftoverNeedsExplicitApproval() throws {
        let l = frame("l", pick: false)
        let plan = CleanupPlan(removals: [l.id])
        #expect(throws: SafetyViolation.removalWithoutApproval(l.id)) {
            try SafetyCheck.validate(plan: plan, groups: [], items: index([l]))
        }
        try SafetyCheck.validate(plan: plan, groups: [], items: index([l]), explicitlyApproved: [l.id])
    }

    @Test func stillJobsValidateKindAndEdits() throws {
        var live = photo("live", kind: .livePhoto); live.pairedVideoBytes = 3_000_000
        var edited = live; edited = MediaItem(id: mid("ed"), kind: .livePhoto, isEdited: true)
        let plain = photo("plain")
        let items = index([live, edited, plain])
        try SafetyCheck.validate(plan: CleanupPlan(stillJobs: [live.id]), groups: [], items: items)
        #expect(throws: SafetyViolation.stillJobOnNonLivePhoto(plain.id)) {
            try SafetyCheck.validate(plan: CleanupPlan(stillJobs: [plain.id]), groups: [], items: items)
        }
        #expect(throws: SafetyViolation.stillJobOnNonLivePhoto(edited.id)) {
            try SafetyCheck.validate(plan: CleanupPlan(stillJobs: [edited.id]), groups: [], items: items)
        }
    }

    @Test func favoriteLivePhotoMayBecomeStill() throws {
        var live = photo("fav", fav: true, kind: .livePhoto); live.pairedVideoBytes = 3_000_000
        try SafetyCheck.validate(plan: CleanupPlan(stillJobs: [live.id]), groups: [], items: index([live]))
    }

    @Test func stillSavingsUseSizeOfPairedVideo() {
        var a = photo("a", kind: .livePhoto); a.pairedVideoBytes = 3_000_000
        let b = photo("b", kind: .livePhoto)
        let plan = CleanupPlan(stillJobs: [a.id, b.id])
        let r = plan.estimatedSavings(items: index([a, b]))
        #expect(r.lowerBound == 2_400_000)
        #expect(r.upperBound == 3_000_000 + CleanupPlan.guessPairedVideo)
        #expect(!plan.isEmpty)
        // A Live Photo that is also removed counts once, as a removal.
        let both = CleanupPlan(removals: [a.id], stillJobs: [a.id])
        #expect(both.stillJobs.isEmpty)
    }

    // MARK: Codable back-compat

    @Test func oldMediaItemJSONStillDecodes() throws {
        let json = """
        {"id":{"raw":"x"},"kind":"video","pixelWidth":10,"pixelHeight":20,"isFavorite":false,"isEdited":false,
         "isLocal":true,"isHDR":false,"isSlowMo":false}
        """
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8))
        #expect(item.isScreenRecording == false)
        #expect(item.burstPick == nil)
        #expect(item.pairedVideoBytes == nil)
        let again = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(
            MediaItem(id: mid("y"), isScreenRecording: true, burstPick: false, pairedVideoBytes: 5)))
        #expect(again.isScreenRecording && again.burstPick == false && again.pairedVideoBytes == 5)
    }
}
