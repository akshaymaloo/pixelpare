import Testing
import Foundation
@testable import PareCore

struct CleanupPlanTests {
    func approvedGroup(keep: String, others: [String], favs: Set<MediaID> = []) -> SimilarGroup {
        SimilarGroup(members: [mid(keep)] + others.map(mid), suggestedKeeper: mid(keep), kind: .similar,
                     favorites: favs, approval: .approved(keep: [mid(keep)]))
    }

    @Test func removalsOnlyFromApprovedGroups() {
        let approved = approvedGroup(keep: "a", others: ["b", "c"])
        var suggested = SimilarGroup(members: [mid("x"), mid("y")], suggestedKeeper: mid("x"), kind: .exact)
        var skipped = suggested; skipped.approval = .skipped
        suggested.approval = .suggested
        let plan = CleanupPlan(groups: [approved, suggested, skipped])
        #expect(plan.removals == [mid("b"), mid("c")])
    }

    @Test func favoritesExcludedFromRemovals() {
        let g = approvedGroup(keep: "a", others: ["b", "c"], favs: [mid("b")])
        #expect(CleanupPlan(groups: [g]).removals == [mid("c")])
    }

    @Test func approvedScreenshotsAdded() {
        let plan = CleanupPlan(groups: [], approvedScreenshots: [mid("s1")])
        #expect(plan.removals == [mid("s1")])
    }

    @Test func savingsSumKnownSizes() {
        let items = index([photo("b", size: 2_000_000), photo("c", size: 3_000_000)])
        let plan = CleanupPlan(removals: [mid("b"), mid("c")])
        #expect(plan.estimatedSavings(items: items) == 5_000_000...5_000_000)
    }

    @Test func savingsUnknownSizeContributesZeroLowAndEstimateHigh() {
        let items = index([photo("b", size: 2_000_000), photo("c", size: nil)])
        let r = CleanupPlan(removals: [mid("b"), mid("c")]).estimatedSavings(items: items)
        #expect(r.lowerBound == 2_000_000)
        #expect(r.upperBound > 2_000_000)
    }

    @Test func videoJobSavingsUseEstimate() {
        let v = video("v", size: 400_000_000)
        let r = CleanupPlan(videoJobs: [v.id: .balanced]).estimatedSavings(items: index([v]))
        let est = PresetPolicy.estimate(v, preset: .balanced)
        #expect(r.lowerBound == 400_000_000 - est.high)
        #expect(r.upperBound == 400_000_000 - est.low)
        #expect(r.lowerBound > 0)
    }

    @Test func videoRemovedAndCompressedCountsOnlyAsRemoval() {
        let v = video("v", size: 400_000_000)
        let plan = CleanupPlan(removals: [v.id], videoJobs: [v.id: .gentle])
        #expect(plan.estimatedSavings(items: index([v])) == 400_000_000...400_000_000)
    }

    @Test func groupInitDropsJobsForRemovedVideos() {
        let g = approvedGroup(keep: "a", others: ["v"])
        let plan = CleanupPlan(groups: [g], videoJobs: [mid("v"): .gentle, mid("w"): .gentle])
        #expect(plan.videoJobs == [mid("w"): .gentle])
    }

    @Test func ineligibleVideoJobSavesNothing() {
        var v = video("v"); v.isHDR = true
        let r = CleanupPlan(videoJobs: [v.id: .gentle]).estimatedSavings(items: index([v]))
        #expect(r == 0...0)
    }

    @Test func screenshotRuleOlderThanDaysNeverFavorites() {
        let now = t0.addingTimeInterval(86_400 * 100)
        let items = [
            photo("old", at: 0, kind: .screenshot),
            photo("oldfav", at: 0, fav: true, kind: .screenshot),
            photo("recent", at: 86_400 * 90, kind: .screenshot),
            photo("photo", at: 0),
        ]
        #expect(ScreenshotRule.candidates(items, now: now) == [mid("old")])
        #expect(ScreenshotRule.candidates(items, olderThan: 5, now: now) == [mid("old"), mid("recent")])
    }
}

struct SafetyCheckTests {
    func group(_ approval: Approval, favs: Set<MediaID> = []) -> SimilarGroup {
        SimilarGroup(members: [mid("a"), mid("b")], suggestedKeeper: mid("a"), kind: .similar,
                     favorites: favs, approval: approval)
    }
    let items = index([photo("a"), photo("b"), photo("s", kind: .screenshot), video("v"), photo("fav", fav: true)])

    @Test func validPlanPasses() throws {
        let g = group(.approved(keep: [mid("a")]))
        try SafetyCheck.validate(plan: CleanupPlan(groups: [g], approvedScreenshots: [mid("s")],
                                                   videoJobs: [mid("v"): .gentle]), groups: [g], items: items)
    }

    @Test func rejectsRemovalFromUnapprovedGroup() {
        for approval in [Approval.suggested, .skipped] {
            let g = group(approval)
            #expect(throws: SafetyViolation.removalWithoutApproval(mid("b"))) {
                try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("b")]), groups: [g], items: items)
            }
        }
    }

    @Test func rejectsRemovingFavorite() {
        #expect(throws: SafetyViolation.removalOfFavorite(mid("fav"))) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("fav")]), groups: [], items: items)
        }
        let g = group(.approved(keep: [mid("a")]), favs: [mid("b")])
        #expect(throws: SafetyViolation.removalOfFavorite(mid("b"))) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("b")]), groups: [g], items: items)
        }
    }

    @Test func rejectsGroupKeepingNothing() {
        let g = group(.approved(keep: [mid("a")]))
        #expect(throws: SafetyViolation.self) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("a"), mid("b")]), groups: [g], items: items)
        }
    }

    @Test func rejectsRemovingKeptMember() {
        let g = group(.approved(keep: [mid("a")]))
        #expect(throws: SafetyViolation.removalOfKeptMember(mid("a"))) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("a")]), groups: [g], items: items)
        }
    }

    @Test func rejectsEmptyApprovedKeepSet() {
        let g = group(.approved(keep: []))
        #expect(throws: SafetyViolation.invalidKeepSet(g.id)) {
            try SafetyCheck.validate(plan: CleanupPlan(), groups: [g], items: items)
        }
    }

    @Test func rejectsUngroupedNonScreenshotRemoval() {
        #expect(throws: SafetyViolation.removalWithoutApproval(mid("a"))) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("a")]), groups: [], items: items)
        }
    }

    @Test func rejectsUnknownItemAndBadVideoJob() {
        #expect(throws: SafetyViolation.unknownItem(mid("zzz"))) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("zzz")]), groups: [], items: items)
        }
        #expect(throws: SafetyViolation.videoJobOnNonVideo(mid("a"))) {
            try SafetyCheck.validate(plan: CleanupPlan(videoJobs: [mid("a"): .gentle]), groups: [], items: items)
        }
    }

    @Test func rejectsVideoInPhotoRemovalsEvenWhenExplicitlyApproved() {
        #expect(throws: SafetyViolation.removalOfVideo(mid("v"))) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("v")]), groups: [], items: items,
                                     explicitlyApproved: [mid("v")])
        }
        #expect(throws: SafetyViolation.removalOfVideo(mid("v"))) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("v")]), groups: [], items: items)
        }
    }

    @Test func explicitApprovalStillWorksForPhotos() throws {
        try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("a")]), groups: [], items: items,
                                 explicitlyApproved: [mid("a")])
    }

    @Test func rejectsVideoMemberOfApprovedGroup() {
        let it = index([photo("a"), video("v")])
        let g = SimilarGroup(members: [mid("a"), mid("v")], suggestedKeeper: mid("a"), kind: .similar,
                             approval: .approved(keep: [mid("a")]))
        #expect(throws: SafetyViolation.removalOfVideo(mid("v"))) {
            try SafetyCheck.validate(plan: CleanupPlan(groups: [g]), groups: [g], items: it)
        }
    }

    @Test func removingEveryMemberIsRejected() {
        let g = group(.approved(keep: [mid("a")]))
        #expect(throws: SafetyViolation.removalOfKeptMember(mid("a"))) {
            try SafetyCheck.validate(plan: CleanupPlan(removals: [mid("a"), mid("b")]), groups: [g], items: items)
        }
    }
}
