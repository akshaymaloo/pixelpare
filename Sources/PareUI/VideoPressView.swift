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
                        if !model.recoveredJobs.isEmpty { RecoveredSection() }
                        controls
                        eligibleList
                        if !model.skippedVideos.isEmpty { skipped }
                    }
                    .padding(compact ? 12 : 20)
                    .frame(maxWidth: 1000).frame(maxWidth: .infinity)
                }
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
                Silk("Step 1 · Settings")
                PresetDial(preset: Bindable(model).preset)
            }
            .frame(maxWidth: compact ? .infinity : 330)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.preset.title).font(.system(.title2, design: .rounded, weight: .heavy)).foregroundStyle(Workshop.ink)
                Text(model.preset.summary).font(.callout).foregroundStyle(Workshop.ink2)
                let r = model.videoSavings(preset: model.preset)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("≈ \(Format.range(r))").font(.system(.title3, design: .monospaced, weight: .bold)).foregroundStyle(Workshop.ink)
                    Chip(text: "Estimate", color: Workshop.amberDark)
                }
                Text(model.selectedVideos.isEmpty ? "If you pressed all \(model.eligibleVideoIDs.count) eligible videos." : "For the \(model.selectedVideos.count) videos you picked.")
                    .font(.footnote).foregroundStyle(Workshop.ink2)
                Divider()
                Label {
                    Text("**The press makes a second copy.** Your original stays in your library until the new one is verified and you approve removing it. Keeping both is fine. It just doesn't save space.")
                        .font(.footnote).foregroundStyle(Workshop.ink)
                } icon: { Image(systemName: "square.on.square").foregroundStyle(Brand.teal) }
                Label {
                    Text("Sizes start as estimates, firm up when you preview a few seconds, and are final once the copy is made.")
                        .font(.footnote).foregroundStyle(Workshop.ink2)
                } icon: { Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Workshop.amberDark) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .workshopModule()
    }

    // MARK: Eligible videos

    private var eligibleList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Silk("Step 2 · Pick videos")
                Spacer()
                Button("Select all") { model.selectAllVideos() }.buttonStyle(.chunkyPlain).controlSize(.small)
                Button("Clear") { model.clearVideos() }.buttonStyle(.chunkyPlain).controlSize(.small)
                    .disabled(model.selectedVideos.isEmpty)
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
                    .rotationEffect(.degrees([-55.0, 0, 55][index]))
                    .animation(calm ? nil : .spring(duration: 0.25, bounce: 0.35), value: index)
            }
            .frame(width: 170, height: 160)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let dx = v.location.x - 85
                set(dx < -28 ? .gentle : dx > 28 ? .smallerResolution : .balanced)
            })
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
            Text(preset.shortSummary).font(.system(size: 11, design: .monospaced)).foregroundStyle(Workshop.ink2)
        }
    }

    private func set(_ p: VideoPreset) {
        guard p != preset else { return }
        Feedback.tick(calm: calm)
        preset = p
    }
}

// MARK: Rows

private struct VideoRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let id: MediaID
    let compare: () -> Void

    var body: some View {
        let item = model.items[id]
        let applicable = model.isApplicable(id, preset: model.preset)
        let selected = model.selectedVideos.contains(id) && applicable
        let est = model.sizeEstimate(for: id)
        HStack(alignment: .top, spacing: 12) {
            Button { model.toggleVideo(id) } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.title2).foregroundStyle(selected ? Brand.teal : Workshop.ink3)
            }
            .buttonStyle(.plain).disabled(!applicable)
            .accessibilityLabel("Press \(model.title(for: id))")
            .accessibilityValue(selected ? "Selected" : "Not selected")

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

            VStack(alignment: .leading, spacing: 4) {
                Text(model.title(for: id)).font(.system(.headline, design: .rounded)).foregroundStyle(Workshop.ink).lineLimit(1)
                if let item { Text(Format.videoDetail(item)).font(.caption).foregroundStyle(Workshop.ink2) }
                if applicable, let est, let size = item?.byteSize {
                    HStack(spacing: 6) {
                        Text("\(Format.bytes(size)) → ≈ \(Format.range(est.low...est.high))")
                            .font(.system(.footnote, design: .monospaced, weight: .semibold)).foregroundStyle(Workshop.ink)
                        stateChip(est.state)
                    }
                } else if !applicable {
                    Text("\(model.preset.title) isn't offered for this video: it's already at or below 1080p.")
                        .font(.caption).foregroundStyle(Workshop.ink3)
                }
                if applicable {
                    HStack(spacing: 8) {
                        if model.previewing.contains(id) {
                            ProgressView().controlSize(.small)
                            Text("Encoding a few seconds…").font(.caption).foregroundStyle(Workshop.ink2)
                        } else {
                            Button("Preview size") { Task { await model.requestPreview(for: id) } }
                                .buttonStyle(.chunkyPlain).controlSize(.small)
                            Button("Compare") { compare() }.buttonStyle(.chunkyPlain).controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
                if let err = model.previewErrors[id] {
                    Text(err).font(.caption).foregroundStyle(Workshop.amberDark)
                }
                if item?.isLocal == false {
                    Label("In iCloud. It's downloaded first.", systemImage: "icloud.and.arrow.down")
                        .font(.caption).foregroundStyle(Workshop.ink2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .opacity(applicable ? 1 : 0.6)
    }

    @ViewBuilder private func stateChip(_ state: SizeEstimate.State) -> some View {
        switch state {
        case .estimate: Chip(text: "Estimate", color: Workshop.amberDark)
        case .previewReady: Chip(text: "Preview ready", color: Workshop.blueDark)
        case .final: Chip(text: "Final", color: Workshop.tealDark)
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
            .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func bar(_ count: Int, _ plan: CleanupPlan, long: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Silk("Step 3 · Press")
                Text(count == 0 ? (model.acceptedRecovered.isEmpty ? "No videos picked" : "\(Format.count(model.acceptedRecovered.count, "unfinished video")) to resume") : "\(Format.count(count, "video")) · \(model.preset.title)")
                    .font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
            }
            Spacer(minLength: 8)
            if long {
                Text("Original stays until the copy is verified and you approve removal.")
                    .font(.footnote).foregroundStyle(Workshop.ink2).frame(maxWidth: 280, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            Button(count == 0 ? "Review receipt" : "Press \(count == 1 ? "a smaller copy" : "\(count) smaller copies")") {
                model.showPlan = true
            }
            .buttonStyle(.chunky).disabled(!model.canExecute)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .workshopModule(radius: 20, screws: false)
    }
}

#if DEBUG
#Preview("Video press") { PreviewHost { NavigationStack { VideoPressView() } } }
#endif
