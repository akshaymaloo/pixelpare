import PareCore
import SwiftUI

struct CompareTarget: Identifiable { let media: MediaID; var id: String { media.raw } }

/// The press: choose a detent, pick videos, see honest sizes, then review the receipt.
struct VideoPressView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var compareTarget: CompareTarget?
    @State private var showSkipped = false

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if model.eligibleVideoIDs.isEmpty && model.skippedVideos.isEmpty && model.recoveredJobs.isEmpty {
                EmptyShelf(symbol: "film", title: "No videos to press", message: "No videos were found.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Make smaller copies of big videos.").font(.callout).foregroundStyle(Workshop.ink2)
                        if !model.recoveredJobs.isEmpty { RecoveredSection() }
                        controls
                        eligibleList
                        if !model.skippedVideos.isEmpty { skipped }
                    }
                    .padding(compact ? 12 : 20)
                    .frame(maxWidth: 1000).frame(maxWidth: .infinity)
                }
                .contentMargins(.bottom, 16, for: .scrollContent)
            }
        }
        .background(BenchBackground())
        .safeAreaInset(edge: .bottom) { PressBar() }
        .navigationTitle("Video press")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { CalmToggle() } }
        .sheet(item: $compareTarget) { target in
            CompareView(id: target.media).environment(model)
        }
    }

    // MARK: Dial + settings

    private var controls: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
        return layout {
            VStack(spacing: 10) {
                Silk("Step 1 · How much smaller?")
                PresetDial(preset: Bindable(model).preset)
            }
            .frame(maxWidth: compact ? .infinity : 330)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.preset.title).font(.system(.title2, design: .rounded, weight: .heavy)).foregroundStyle(Workshop.ink)
                Text(model.preset.summary).font(.callout).foregroundStyle(Workshop.ink2)
                savings
                Divider()
                howItWorks
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .workshopModule()
    }

    private var savings: some View {
        let r = model.videoSavings(preset: model.preset)
        let picked = model.applicableSelectedVideos.count
        return VStack(alignment: .leading, spacing: 4) {
            if picked == 0 {
                Text("Could save about").font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
                Text(Format.range(r)).font(.system(.title3, design: .monospaced, weight: .bold)).foregroundStyle(Workshop.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("if you pick all \(model.eligibleVideoIDs.count)").font(.footnote).foregroundStyle(Workshop.ink2)
            } else {
                Text("Saves about").font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
                HStack(spacing: 8) {
                    Text(Format.range(r)).font(.system(.title3, design: .monospaced, weight: .bold)).foregroundStyle(Workshop.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Chip(text: "Estimate", color: Workshop.amberDark).fixedSize()
                }
                Text("For \(Format.count(picked, "video")), once the originals are removed.").font(.footnote).foregroundStyle(Workshop.ink2)
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Silk("How it works")
            step(1, "Makes a smaller copy")
            step(2, "Checks it plays the same")
            step(3, "You decide when to remove the original")
            Text("Sizes are estimates until you check a sample or the copy is made.")
                .font(.caption).foregroundStyle(Workshop.ink3).padding(.top, 2)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(.caption, design: .rounded, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Brand.teal))
            Text(text).font(.footnote).foregroundStyle(Workshop.ink)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Eligible videos

    private var eligibleList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack { Silk("Step 2 · Pick videos").fixedSize(); Spacer(); pickButtons }
                VStack(alignment: .leading, spacing: 8) { Silk("Step 2 · Pick videos"); pickButtons }
            }
            .padding(.bottom, 6)
            ForEach(model.eligibleVideoIDs, id: \.self) { id in
                VideoRow(id: id) { compareTarget = CompareTarget(media: id) }
                if id != model.eligibleVideoIDs.last { Divider().overlay(Workshop.benchDark.opacity(0.6)) }
            }
            if model.eligibleVideoIDs.isEmpty {
                Text("None of your videos are worth pressing right now.").font(.callout).foregroundStyle(Workshop.ink2)
            }
        }
        .padding(20)
        .workshopModule()
    }

    private var pickButtons: some View {
        HStack(spacing: 8) {
            Button("Select all") { model.selectAllVideos() }.buttonStyle(.chunkyPlain).controlSize(.small)
            Button("Clear") { model.clearVideos() }.buttonStyle(.chunkyPlain).controlSize(.small)
                .disabled(model.selectedVideos.isEmpty)
        }
        .lineLimit(1).fixedSize()
    }

    private var skipped: some View {
        DisclosureGroup(isExpanded: $showSkipped) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.skippedVideos, id: \.id) { s in
                    HStack(spacing: 10) {
                        ThumbnailView(id: s.id, maxPixel: 120).frame(width: 44, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.title(for: s.id)).font(.subheadline.weight(.semibold)).foregroundStyle(Workshop.ink)
                            Text(s.reason.message).font(.caption).foregroundStyle(Workshop.ink2)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Skipped · \(Format.count(model.skippedVideos.count, "video"))")
                .font(.system(.headline, design: .rounded)).foregroundStyle(Workshop.ink)
        }
        .padding(20).workshopModule()
        .tint(Workshop.ink)
    }
}

// MARK: Dial

struct PresetDial: View {
    @Binding var preset: VideoPreset
    @Environment(\.calm) private var calm
    @State private var live: CGFloat?

    private let order = VideoPreset.allCases
    private var index: Int { order.firstIndex(of: preset) ?? 0 }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    for (i, deg) in [-55.0, 0, 55].enumerated() {
                        let a = Angle.degrees(deg - 90).radians
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + cos(a) * 62, y: c.y + sin(a) * 62))
                        p.addLine(to: CGPoint(x: c.x + cos(a) * 72, y: c.y + sin(a) * 72))
                        ctx.stroke(p, with: .color(i == index ? Brand.teal : Workshop.ink3), style: .init(lineWidth: i == index ? 4 : 2.5, lineCap: .round))
                    }
                }
                Circle().fill(LinearGradient(colors: [Brand.teal, Brand.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 112, height: 112)
                    .overlay(Circle().strokeBorder(Workshop.ink, lineWidth: 4))
                    .shadow(color: Workshop.shadow.opacity(0.35), radius: 8, y: 6)
                Capsule().fill(Workshop.paper).frame(width: 7, height: 38).offset(y: -29)
                    .rotationEffect(.degrees(live.map { DialDetent.liveAngle(offset: $0) } ?? DialDetent(preset).angle))
                    .animation(calm ? nil : .spring(duration: 0.25, bounce: 0.35), value: index)
                    .animation(nil, value: live)
            }
            .frame(width: 170, height: 160)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.location.x - 85
                    live = calm ? nil : dx
                    set(DialDetent.nearest(offset: dx).preset)
                }
                .onEnded { _ in live = nil })
            .sensoryFeedback(trigger: preset) { _, _ in calm ? nil : .selection }
            .accessibilityElement()
            .accessibilityLabel("Preset dial")
            .accessibilityValue(preset.title)
            .accessibilityAdjustableAction { d in
                let next = min(max(0, index + (d == .increment ? 1 : -1)), order.count - 1)
                set(order[next])
            }

            HStack(spacing: 6) {
                ForEach(order, id: \.self) { p in
                    Button { set(p) } label: {
                        Text(p.title).font(.system(.footnote, design: .rounded, weight: .bold))
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(p == preset ? .white : Workshop.ink)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(p == preset ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Workshop.paper)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func set(_ p: VideoPreset) {
        guard p != preset else { return }
        preset = p
    }
}

// MARK: Rows

private struct VideoRow: View {
    @Environment(AppModel.self) private var model
    let id: MediaID
    let compare: () -> Void

    var body: some View {
        let item = model.items[id]
        let applicable = model.isApplicable(id, preset: model.preset)
        let selected = model.selectedVideos.contains(id) && applicable
        let est = model.sizeEstimate(for: id)
        HStack(spacing: 4) {
            Button { model.toggleVideo(id) } label: {
                HStack(spacing: 12) {
                    PolaroidFrame(corner: 5, border: 3, bottom: 3) {
                        ThumbnailView(id: id, maxPixel: 200).frame(width: 72, height: 54)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let d = item?.duration {
                            Text(Format.duration(d)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(.black.opacity(0.65)))
                                .offset(x: -2, y: -2)
                        }
                    }
                    .overlay(alignment: .topLeading) { MarkBadge(on: selected, disabled: !applicable).offset(x: -6, y: -6) }
                    details(item, applicable: applicable, est: est)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!applicable)
            .accessibilityLabel("Press \(model.title(for: id))")
            .accessibilityValue(selected ? "Selected" : "Not selected")

            if applicable { trailing }
        }
        .padding(.vertical, 8)
        .opacity(applicable ? 1 : 0.6)
    }

    @ViewBuilder private var trailing: some View {
        if model.previewing.contains(id) {
            ProgressView().controlSize(.small).frame(width: 44, height: 44)
        } else {
            Button(action: compare) {
                Image(systemName: "eye").font(.system(.body, weight: .semibold)).foregroundStyle(Brand.teal)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Check quality of \(model.title(for: id))")
        }
    }

    private func details(_ item: MediaItem?, applicable: Bool, est: SizeEstimate?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.title(for: id)).font(.system(.headline, design: .rounded)).foregroundStyle(Workshop.ink).lineLimit(1)
            if let item {
                Text(Format.videoDetail(item)).font(.caption).foregroundStyle(Workshop.ink2).lineLimit(1).minimumScaleFactor(0.8)
            }
            if applicable, let est, let size = item?.byteSize {
                // The size line shows the midpoint so it fits one line; the range stays on the savings line.
                let after = Format.bytes((est.low + est.high) / 2)
                let saved = Format.range(max(0, size - est.high)...max(0, size - est.low))
                Text("\(Format.bytes(size)) → ≈ \(after)")
                    .font(.system(.footnote, design: .monospaced, weight: .semibold)).foregroundStyle(Workshop.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                let saves = size - est.high < 1_000_000 ? "saves little" : "saves ≈ \(saved)"
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        Text(saves).foregroundStyle(Workshop.tealDark)
                        Text(stateWord(est.state)).foregroundStyle(Workshop.ink3)
                    }
                    Text(saves).foregroundStyle(Workshop.tealDark)
                }
                .font(.system(.caption, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.6)
            } else if !applicable {
                Text("Already 1080p or smaller — \(model.preset.title) doesn't apply.")
                    .font(.caption).foregroundStyle(Workshop.ink3).lineLimit(2)
            }
            if let err = model.previewErrors[id] {
                Text(err).font(.caption).foregroundStyle(Workshop.amberDark).lineLimit(2)
            }
            if item?.isLocal == false {
                Label("In iCloud · downloads first", systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(Workshop.ink2).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private func stateWord(_ state: SizeEstimate.State) -> String {
        switch state {
        case .estimate: "estimate"
        case .previewReady: "measured"
        case .final: "final"
        }
    }
}

/// Jobs a previous session left unfinished. They stay on hold until the user resumes or discards them.
private struct RecoveredSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Silk("Unfinished from last time")
            Text("These videos were mid-press when PixelPare last stopped. They don't start on their own. Resume the ones you want in your next press, or discard them. Originals are never touched by either.")
                .font(.footnote).foregroundStyle(Workshop.ink2)
            ForEach(model.recoveredJobs, id: \.original) { job in
                let accepted = model.acceptedRecovered.contains(job.original)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title(for: job.original)).font(.footnote.weight(.semibold)).foregroundStyle(Workshop.ink)
                    HStack(spacing: 8) {
                        Button(accepted ? "Will resume" : "Resume") { model.setRecoveredAccepted(job.original, !accepted) }
                            .buttonStyle(accepted ? .chunky : .chunkyPlain).controlSize(.small)
                            .accessibilityHint(accepted ? "Tap to leave it for later" : "Adds it to your next press")
                        Button("Discard") { Task { await model.discardRecovered(job.original) } }
                            .buttonStyle(.chunkyPlain).controlSize(.small)
                            .accessibilityHint("Cancels this job. The original is untouched")
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).workshopModule(radius: 20, screws: false)
    }
}

private struct PressBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.applicableSelectedVideos.count
        let plan = model.plan
        ViewThatFits(in: .horizontal) { bar(count, plan, long: true); bar(count, plan, long: false) }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 6)
            .background(.regularMaterial)
    }

    private func summary(_ count: Int) -> String {
        if count == 0 {
            return model.acceptedRecovered.isEmpty ? "No videos picked"
                : "\(Format.count(model.acceptedRecovered.count, "unfinished video")) to resume"
        }
        let saves = Format.range(model.videoSavings(preset: model.preset))
        return "\(Format.count(count, "video")) · \(model.preset.title) · saves ≈ \(saves)"
    }

    private func shortSummary(_ count: Int) -> String {
        count == 0 ? summary(count) : "\(Format.count(count, "video")) · \(model.preset.title)"
    }

    private func bar(_ count: Int, _ plan: CleanupPlan, long: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Silk("Step 3 · Make copies")
                ViewThatFits(in: .horizontal) {
                    Text(summary(count)).lineLimit(1).fixedSize()
                    Text(shortSummary(count)).lineLimit(1).minimumScaleFactor(0.75)
                }
                .font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
            }
            Spacer(minLength: 8)
            if long {
                Text("Original stays until the copy is verified and you approve removal.")
                    .font(.footnote).foregroundStyle(Workshop.ink2).frame(maxWidth: 280, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Button("Review") {
                    model.showPlan = true
                }
                .buttonStyle(.chunky).disabled(!model.canExecute)
                .lineLimit(1).fixedSize()
                .accessibilityIdentifier("press-receipt")
                if !model.canExecute {
                    Text("Pick at least one video").font(.caption2).foregroundStyle(Workshop.ink2)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .workshopModule(radius: 20, screws: false)
    }
}

#if DEBUG
#Preview("Video press") { PreviewHost { NavigationStack { VideoPressView() } } }
#endif
