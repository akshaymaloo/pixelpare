import CoreGraphics
import PareCore
import Testing
@testable import PareUI

@Suite struct SwipeDecisionTests {
    private func resolve(_ dx: CGFloat = 0, _ dy: CGFloat, keeper: Bool = false, favorite: Bool = false, marked: Bool = false) -> SwipeDecision {
        SwipeDecision.resolve(translation: CGSize(width: dx, height: dy), isKeeper: keeper, isFavorite: favorite, isMarked: marked)
    }

    @Test func upMarksAndDownUndoes() {
        #expect(resolve(0, -80) == .mark)
        #expect(resolve(0, 80, marked: true) == .unmark)
        #expect(resolve(0, -80, marked: true) == .none)
        #expect(resolve(0, 80) == .none)
    }

    @Test func belowThresholdOrSidewaysDoesNothing() {
        #expect(resolve(0, -59) == .none)
        #expect(resolve(100, -70) == .none)
        #expect(resolve(0, -60) == .mark)
    }

    @Test func favoritesAreProtectedAndKeepersResist() {
        #expect(resolve(0, -90, favorite: true) == .protected)
        #expect(resolve(0, -90, keeper: true) == .resist)
        #expect(resolve(0, -90, keeper: true, favorite: true) == .protected)
        #expect(resolve(0, 90, favorite: true, marked: true) == .none)
        #expect(resolve(0, 90, keeper: true, marked: true) == .none)
    }

    @Test func rubberBandIsBounded() {
        #expect(SwipeDecision.rubberBand(0) == 0)
        #expect(abs(SwipeDecision.rubberBand(-10_000, limit: 90)) < 90)
        #expect(SwipeDecision.rubberBand(-50) < 0)
        #expect(SwipeDecision.rubberBand(30) < SwipeDecision.rubberBand(60))
    }
}

@Suite struct GroupSwipeTests {
    @Test func horizontalSwipesMoveGroups() {
        #expect(GroupSwipe.resolve(translation: CGSize(width: -120, height: 10)) == .next)
        #expect(GroupSwipe.resolve(translation: CGSize(width: 120, height: 10)) == .previous)
        #expect(GroupSwipe.resolve(translation: CGSize(width: 50, height: 0)) == .none)
        #expect(GroupSwipe.resolve(translation: CGSize(width: 100, height: 90)) == .none)
        #expect(GroupSwipe.next.delta == 1 && GroupSwipe.previous.delta == -1)
    }
}

@Suite struct DialDetentTests {
    @Test func snapsToNearest() {
        #expect(DialDetent.nearest(offset: -100) == .gentle)
        #expect(DialDetent.nearest(offset: -20) == .balanced)
        #expect(DialDetent.nearest(offset: 0) == .balanced)
        #expect(DialDetent.nearest(offset: 29) == .smallerResolution)
        #expect(DialDetent.nearest(offset: 500) == .smallerResolution)
        #expect(DialDetent.nearest(offset: 10, spacing: 0) == .balanced)
    }

    @Test func roundTripsPresets() {
        for p in VideoPreset.allCases { #expect(DialDetent(p).preset == p) }
        #expect(DialDetent.liveAngle(offset: 1000) == 55)
        #expect(DialDetent.liveAngle(offset: -1000) == -55)
    }
}

@Suite struct CompareAndReceiptTests {
    @Test func splitIsClamped() {
        #expect(CompareSplit.fraction(x: -5, width: 200) == 0)
        #expect(CompareSplit.fraction(x: 300, width: 200) == 1)
        #expect(CompareSplit.fraction(x: 50, width: 200) == 0.25)
        #expect(CompareSplit.fraction(x: 50, width: 0) == 0.5)
    }

    @Test func receiptCannotBeSwipedAwayDuringWork() {
        #expect(!ReceiptDismissal.isLocked(isRemoving: false, isWorking: false))
        #expect(ReceiptDismissal.isLocked(isRemoving: true, isWorking: false))
        #expect(ReceiptDismissal.isLocked(isRemoving: false, isWorking: true))
    }
}
