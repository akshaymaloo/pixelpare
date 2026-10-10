import PareCore
import SwiftUI

struct ThumbnailView: View {
    @Environment(AppModel.self) private var model
    let id: MediaID
    var maxPixel = 360
    var fill = true
    @State private var image: CGImage?

    var body: some View {
        Rectangle().fill(Workshop.plasticDark)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                }
            }
            .clipped()
            .task(id: id) { image = await model.thumbnail(id, maxPixel: maxPixel) }
    }
}

/// A white photo card, like the one in the app icon.
struct PolaroidFrame<Content: View>: View {
    var corner: CGFloat = 6
    var border: CGFloat = 6
    var bottom: CGFloat = 6
    @ViewBuilder var content: Content
    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: max(2, corner - 2), style: .continuous))
            .padding(.horizontal, border).padding(.top, border).padding(.bottom, bottom)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Workshop.paper))
            .shadow(color: Workshop.shadow.opacity(0.3), radius: 5, y: 3)
    }
}

/// Photo cards fanned out of a slot. They lift a little when `lifted` unless Calm mode is on.
struct FannedCards: View {
    let ids: [MediaID]
    var lifted = false
    @Environment(\.calm) private var calm

    var body: some View {
        ZStack {
            ForEach(Array(ids.prefix(3).enumerated()), id: \.element) { index, id in
                let spread = Double(index) - 1
                PolaroidFrame(corner: 8, border: 7, bottom: 22) {
                    ThumbnailView(id: id, maxPixel: 300).aspectRatio(4 / 3, contentMode: .fit)
                }
                .frame(width: 130)
                .rotationEffect(.degrees(spread * 9))
                .offset(x: spread * 34, y: -(lifted && !calm ? 12 : 0) + abs(spread) * 6)
                .zIndex(Double(index))
            }
        }
        .animation(calm ? nil : .easeOut(duration: 0.18), value: lifted)
        .accessibilityHidden(true)
    }
}

/// Film reel in the icon's colours.
struct ReelIcon: View {
    var spinning = false
    var size: CGFloat = 80
    @Environment(\.calm) private var calm
    @State private var angle = 0.0

    var body: some View {
        ZStack {
            Circle().fill(Brand.gradient)
            Circle().strokeBorder(Workshop.ink, lineWidth: 4)
            ForEach(0..<4, id: \.self) { i in
                hole.offset(y: -26).rotationEffect(.degrees(Double(i) * 90))
            }
            hole
        }
        .frame(width: 80, height: 80)
        .rotationEffect(.degrees(angle))
        .scaleEffect(size / 80)
        .frame(width: size, height: size)
        .onAppear {
            if spinning && !calm { withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { angle = 360 } }
        }
        .accessibilityHidden(true)
    }

    private var hole: some View {
        Circle().fill(Workshop.paper).frame(width: 14, height: 14)
            .overlay(Circle().fill(Workshop.ink).frame(width: 6, height: 6))
    }
}

/// Half-dial that shows a *range*, never a single number.
struct RangeGauge: View {
    let low: Int64
    let high: Int64
    let maxValue: Int64

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 14)
            let radius = max(10, min(size.width / 2, size.height) - 12)
            func fraction(_ v: Int64) -> Double { min(1, Double(v) / Double(max(1, maxValue))) }
            func degrees(_ v: Int64) -> Angle { .degrees(180 + 180 * fraction(v)) }
            func arc(_ from: Angle, _ to: Angle, _ r: CGFloat) -> Path {
                Path { $0.addArc(center: center, radius: r, startAngle: from, endAngle: to, clockwise: false) }
            }
            ctx.stroke(arc(.degrees(180), .degrees(360), radius), with: .color(Workshop.ink3.opacity(0.6)), lineWidth: 1.5)
            for i in 0...10 {
                let a = Angle.degrees(180 + 18 * Double(i)).radians
                let inner = radius - (i % 5 == 0 ? 12 : 7)
                var p = Path()
                p.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
                p.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
                ctx.stroke(p, with: .color(Workshop.ink3), lineWidth: 1.5)
            }
            if high > 0 {
                let end = degrees(max(high, low + maxValue / 40))
                ctx.stroke(arc(degrees(low), end, radius - 22), with: .color(Brand.teal),
                           style: .init(lineWidth: 9, lineCap: .round))
                let mid = Angle.degrees((degrees(low).degrees + end.degrees) / 2).radians
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: CGPoint(x: center.x + cos(mid) * (radius - 10), y: center.y + sin(mid) * (radius - 10)))
                ctx.stroke(needle, with: .color(Color(hex: 0xE5533D)), style: .init(lineWidth: 2.5, lineCap: .round))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)), with: .color(Workshop.ink))
        }
        .accessibilityElement()
        .accessibilityLabel("Estimated space gauge")
        .accessibilityValue("\(Format.bytes(low)) to \(Format.bytes(high))")
    }
}

/// Bottom strip shared by the review screens: what is marked so far, and the way to the receipt.
struct PlanBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let plan = model.plan
        ViewThatFits(in: .horizontal) {
            bar(plan, showNote: true)
            bar(plan, showNote: false)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func bar(_ plan: CleanupPlan, showNote: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Silk("Pending plan")
                Text(summary(plan)).font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
            }
            Spacer(minLength: 8)
            if showNote {
                Text("Nothing is removed until you review the whole plan.")
                    .font(.footnote).foregroundStyle(Workshop.ink2).frame(maxWidth: 260, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            Button("Review receipt") { model.showPlan = true }
                .buttonStyle(.chunky).disabled(plan.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .workshopModule(radius: 20, screws: false)
    }

    private func summary(_ plan: CleanupPlan) -> String {
        var parts: [String] = []
        if !plan.removals.isEmpty { parts.append("\(Format.count(plan.removals.count, "item")) marked") }
        if !plan.stillJobs.isEmpty { parts.append(Format.count(plan.stillJobs.count, "still") + " to make") }
        if !plan.videoJobs.isEmpty { parts.append(Format.count(plan.videoJobs.count, "video") + " to press") }
        return parts.isEmpty ? "Nothing marked yet" : parts.joined(separator: " · ")
    }
}

struct CalmToggle: View {
    @Environment(AppModel.self) private var model
    var iconOnly = false
    var body: some View {
        @Bindable var m = model
        Toggle(isOn: $m.calmMode) {
            if iconOnly { Label("Calm mode", systemImage: "leaf").labelStyle(.iconOnly) } else { Label("Calm", systemImage: "leaf") }
        }
        .toggleStyle(.button)
        .accessibilityLabel("Calm mode")
            .help("Calm mode turns off animation, sound and haptics")
            .accessibilityHint("Turns off animation, sound and haptics")
    }
}
