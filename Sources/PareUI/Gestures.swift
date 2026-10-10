import PareCore
import SwiftUI

// Pure decision logic for the tactile gestures. Gestures only mark or move, never delete, and every
// outcome maps onto an existing AppModel action (toggleKeep, setKeeper, rescan, preset binding).

/// What a vertical swipe on a photo card means.
enum SwipeDecision: Equatable {
    case mark, unmark, none
    /// A favorite can never be marked: shake and say "Protected".
    case protected
    /// The keeper can never be marked: a tiny resist, no action.
    case resist

    static let threshold: CGFloat = 60

    /// Up marks, down undoes. Needs a mostly vertical drag past the threshold.
    static func resolve(translation: CGSize, isKeeper: Bool, isFavorite: Bool, isMarked: Bool,
                        threshold: CGFloat = SwipeDecision.threshold) -> SwipeDecision {
        guard isVertical(translation), abs(translation.height) >= threshold else { return .none }
        if translation.height < 0 {
            if isFavorite { return .protected }
            if isKeeper { return .resist }
            return isMarked ? .none : .mark
        }
        if isFavorite || isKeeper { return .none }
        return isMarked ? .unmark : .none
    }

    static func isVertical(_ t: CGSize) -> Bool { abs(t.height) > abs(t.width) * 1.2 }

    /// The card follows the finger with diminishing return, never more than `limit`.
    static func rubberBand(_ distance: CGFloat, limit: CGFloat = 90) -> CGFloat {
        guard limit > 0 else { return 0 }
        let d = abs(distance)
        let eased = limit * (1 - 1 / (d / limit + 1))
        return distance < 0 ? -eased : eased
    }
}

/// A horizontal swipe on the light table surface.
enum GroupSwipe: Equatable {
    case next, previous, none

    static let threshold: CGFloat = 80

    static func resolve(translation: CGSize, threshold: CGFloat = GroupSwipe.threshold) -> GroupSwipe {
        guard abs(translation.width) >= threshold, abs(translation.width) > abs(translation.height) * 2 else { return .none }
        return translation.width < 0 ? .next : .previous
    }

    var delta: Int { switch self { case .next: 1; case .previous: -1; case .none: 0 } }
}

/// The three detents of the preset dial.
enum DialDetent: Int, CaseIterable, Equatable {
    case gentle, balanced, smallerResolution

    /// Horizontal distance between detents while dragging.
    static let spacing: CGFloat = 56

    init(_ preset: VideoPreset) {
        switch preset { case .gentle: self = .gentle; case .balanced: self = .balanced; case .smallerResolution: self = .smallerResolution }
    }

    var preset: VideoPreset {
        switch self { case .gentle: .gentle; case .balanced: .balanced; case .smallerResolution: .smallerResolution }
    }

    var angle: Double { [-55.0, 0, 55][rawValue] }

    /// Snaps a drag offset from the centre to the closest detent.
    static func nearest(offset: CGFloat, spacing: CGFloat = DialDetent.spacing) -> DialDetent {
        guard spacing > 0 else { return .balanced }
        let i = Int((offset / spacing).rounded()) + 1
        return DialDetent(rawValue: min(max(i, 0), 2)) ?? .balanced
    }

    /// Pointer angle that follows the finger, held within the dial's range.
    static func liveAngle(offset: CGFloat, spacing: CGFloat = DialDetent.spacing) -> Double {
        let a = Double(offset / spacing) * 55
        return min(max(a, -55), 55)
    }
}

/// Position of the A/B divider as a 0...1 fraction.
enum CompareSplit {
    static func fraction(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0.5 }
        return Double(min(max(x / width, 0), 1))
    }
}

/// Whether the receipt sheet may be swiped away: never during a removal or a run.
enum ReceiptDismissal {
    static func isLocked(isRemoving: Bool, isWorking: Bool) -> Bool { isRemoving || isWorking }
}

// MARK: Views

/// A short sideways wiggle for "can't do that".
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var amount: CGFloat = 7
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(travel * .pi * 3), y: 0))
    }
}

/// Full-screen enlarged look at one photo; releasing the press or tapping dismisses it.
struct PeekOverlay: View {
    let id: MediaID
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            ThumbnailView(id: id, maxPixel: 1800, fill: false)
                .background(.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(18)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Photo preview")
        .accessibilityAction(named: "Close preview", dismiss)
    }
}
