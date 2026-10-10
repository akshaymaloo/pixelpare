import PareCore
import SwiftUI

/// A paper receipt: a sheet of lines with a dashed rule between sections.
private struct ReceiptPaper<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Workshop.paper)
                    .shadow(color: Workshop.shadow.opacity(0.25), radius: 10, y: 6)
            )
            .foregroundStyle(Workshop.ink)
    }
}

private struct Rule: View {
    var body: some View {
        Line().stroke(Workshop.ink3, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(height: 1)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

private struct ReceiptLine: View {
    let label: String
    let value: String
    var detail: String?
    var strong = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(strong ? .headline : .subheadline, design: .monospaced, weight: strong ? .bold : .regular))
                Spacer(minLength: 12)
                Text(value).font(.system(strong ? .headline : .subheadline, design: .monospaced, weight: .bold))
                    .multilineTextAlignment(.trailing)
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(Workshop.ink2) }
        }
        .accessibilityElement(children: .combine)
    }
}

private func receiptHeader(_ title: String) -> some View {
    VStack(spacing: 4) {
        Text("PIXELPARE").font(.system(.title2, design: .monospaced, weight: .heavy)).tracking(4)
        Silk(title)
        Text(Date().formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Workshop.ink2)
    }
    .frame(maxWidth: .infinity)
}

// MARK: Before: plan review

struct PlanReceiptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let plan = model.plan
        let groupRemovals = model.groups.reduce(into: Set<MediaID>()) { $0.formUnion($1.approvedRemovals) }
        let screenshots = plan.removals.intersection(model.selectedScreenshots).subtracting(groupRemovals)
        let blurry = plan.removals.intersection(model.selectedBlurry).subtracting(groupRemovals).subtracting(screenshots)
        let videos = model.applicableSelectedVideos
        let recovered = model.recoveredJobs.filter { model.acceptedRecovered.contains($0.original) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ReceiptPaper {
                    receiptHeader("Receipt · plan review")
                    Rule()
                    if groupRemovals.isEmpty && screenshots.isEmpty && blurry.isEmpty && videos.isEmpty && recovered.isEmpty {
                        Text("Nothing marked.").font(.system(.subheadline, design: .monospaced))
                    }
                    if !groupRemovals.isEmpty {
                        ReceiptLine(label: "Lookalikes removed", value: "\(groupRemovals.count) · \(Format.bytes(bytes(groupRemovals)))",
                                    detail: "From \(Format.count(model.approvedGroupCount, "approved group")). Every group keeps at least one photo.")
                    }
                    if !screenshots.isEmpty {
                        ReceiptLine(label: "Old screenshots removed", value: "\(screenshots.count) · \(Format.bytes(bytes(screenshots)))",
                                    detail: "Older than 30 days, marked by you.")
                    }
                    if !blurry.isEmpty {
                        ReceiptLine(label: "Blurry shots removed", value: "\(blurry.count) · \(Format.bytes(bytes(blurry)))",
                                    detail: "Marked by you, one by one.")
                    }
                    if !videos.isEmpty {
                        ReceiptLine(label: "Second copies (\(model.preset.title))", value: "\(videos.count)",
                                    detail: "Smaller copies are made and verified first. Originals stay until you approve their removal.")
                        ForEach(videos, id: \.self) { id in videoLine(id) }
                    }
                    if !recovered.isEmpty {
                        ReceiptLine(label: "Unfinished from last time", value: "\(recovered.count)",
                                    detail: "You chose to resume these. They are finished and verified the same way; originals stay until you approve.")
                    }
                    let favorites = model.protectedFavoriteCount
                    ReceiptLine(label: "Favorites are never included", value: favorites == 0 ? "none skipped" : "\(favorites) protected",
                                detail: favorites == 0 ? "No favorites were in the approved groups." : "Favorites in approved groups were skipped.")
                    Rule()
                    ReceiptLine(label: "Estimated space", value: "≈ \(Format.range(model.planSavings))", strong: true)
                    Text("An estimate: each item counts once and new copies are subtracted. Video savings only arrive after you remove the originals.")
                        .font(.caption).foregroundStyle(Workshop.ink2)
                }
                if !plan.removals.isEmpty {
                    Banner(symbol: "exclamationmark.triangle.fill", text: "Check your iCloud storage first. Removed items normally stay in Recently Deleted for 30 days. But if your iCloud storage is over its limit, they can be deleted immediately and can't be recovered. Removal applies on all your devices.")
                }
                if !videos.isEmpty {
                    Banner(symbol: "info.circle", tint: Brand.blue, text: "A pressed video is a new item: date, location, favorite and albums are carried over, but it won't be in shared albums or Memories, and links to the old one break. Videos in iCloud are downloaded first. The press keeps running while PixelPare is open and picks up where it left off if it quits.")
                }
                if let err = model.errorMessage { Text(err).font(.callout).foregroundStyle(.red) }
                HStack {
                    Button("Back to the bench") { model.errorMessage = nil; dismiss() }
                        .buttonStyle(.chunkyPlain).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(confirmLabel(plan.removals.count, videos.count, recovered.count)) { model.executePlan() }
                        .buttonStyle(.chunky).keyboardShortcut(.defaultAction).disabled(!model.canExecute || model.isRemoving)
                }
            }
            .padding(22)
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .background(BenchBackground())
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }

    private func bytes(_ ids: Set<MediaID>) -> Int64 { ids.reduce(0) { $0 + (model.items[$1]?.byteSize ?? 0) } }

    private func videoLine(_ id: MediaID) -> some View {
        let size = model.items[id]?.byteSize
        let est = model.sizeEstimate(for: id)
        return HStack {
            Text(model.title(for: id)).font(.system(.caption, design: .monospaced)).lineLimit(1)
            Spacer()
            if let size, let est {
                Text("\(Format.bytes(size)) → ≈ \(Format.range(est.low...est.high))").font(.system(.caption, design: .monospaced))
            }
        }
        .foregroundStyle(Workshop.ink2).padding(.leading, 12)
    }

    private func confirmLabel(_ photos: Int, _ videos: Int, _ resumed: Int) -> String {
        if videos == 0, resumed > 0 {
            return photos > 0 ? "Remove \(photos) and resume \(resumed)" : "Resume \(Format.count(resumed, "video"))"
        }
        return switch (photos > 0, videos > 0) {
        case (true, true): "Remove \(photos) and press \(videos)"
        case (true, false): "Remove \(Format.count(photos, "photo"))"
        default: "Press \(videos == 1 ? "a smaller copy" : "\(videos) smaller copies")"
        }
    }
}

// MARK: During

struct WorkingView: View {
    @Environment(AppModel.self) private var model
    let progress: WorkProgress

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ReelIcon(spinning: !progress.paused, size: 90).padding(.top, 20)
                Text(progress.title).font(.system(.title, design: .rounded, weight: .heavy)).foregroundStyle(Workshop.ink)
                if progress.total > 0 {
                    ProgressView(value: Double(progress.index), total: Double(max(1, progress.total)))
                        .tint(Brand.teal).frame(maxWidth: 380)
                } else {
                    ProgressView().controlSize(.large)
                }
                if !progress.detail.isEmpty {
                    Text(progress.detail).font(.callout).foregroundStyle(Workshop.ink2).multilineTextAlignment(.center)
                }
                if !progress.jobs.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(progress.jobs) { job in
                            JobRowView(job: job)
                            if job.id != progress.jobs.last?.id { Divider() }
                        }
                    }
                    .padding(16).workshopModule(radius: 20, screws: false)
                    .frame(maxWidth: 560)
                }
                if progress.savedBytes > 0 {
                    Text("Smaller copies so far would save about \(Format.bytes(progress.savedBytes)) once you approve removing their originals.")
                        .font(.footnote).foregroundStyle(Workshop.ink2).multilineTextAlignment(.center)
                }
                if progress.total > 0 {
                    Button("Pause") { model.stopWork() }.buttonStyle(.chunkyPlain)
                }
                Text("Originals are never touched while this runs. If PixelPare quits, the press resumes next time. The video in progress starts over.")
                    .font(.footnote).foregroundStyle(Workshop.ink3).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .padding(24).frame(maxWidth: .infinity)
        }
        .background(BenchBackground())
    }
}

private struct JobRowView: View {
    @Environment(AppModel.self) private var model
    let job: JobRow

    var body: some View {
        HStack(spacing: 12) {
            PolaroidFrame(corner: 4, border: 2, bottom: 2) { ThumbnailView(id: job.id, maxPixel: 100).frame(width: 40, height: 30) }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title(for: job.id)).font(.subheadline.weight(.semibold)).foregroundStyle(Workshop.ink).lineLimit(1)
                Text(job.message).font(.caption).foregroundStyle(tint)
                if let f = job.fraction { ProgressView(value: f).tint(Brand.teal) }
            }
            Spacer(minLength: 0)
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch job.phase {
        case .queued: "clock"
        case .working: "gearshape.2"
        case .waiting: "hourglass"
        case .retrying: "arrow.triangle.2.circlepath"
        case .copyReady: "checkmark.circle.fill"
        case .skipped: "arrow.uturn.right.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }
    private var tint: Color {
        switch job.phase {
        case .copyReady: Workshop.tealDark
        case .failed, .waiting, .retrying: Workshop.amberDark
        default: Workshop.ink2
        }
    }
}

// MARK: After: honest recap

struct RecapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let summary: RunSummary
    @State private var confirmRemoval = false

    var body: some View {
        let pending = summary.pendingOriginals
        ScrollView {
            VStack(spacing: 16) {
                ReceiptPaper {
                    receiptHeader("Receipt · what happened")
                    Rule()
                    ReceiptLine(label: "Photos removed",
                                value: summary.removedCount == 0 ? "none" : "\(summary.removedCount) · \(Format.bytes(summary.removedBytes))")
                    ReceiptLine(label: "Smaller copies made", value: "\(summary.copies.count)",
                                detail: summary.copies.isEmpty ? nil : "Each one was verified before it was counted.")
                    ReceiptLine(label: "Originals removed", value: "\(summary.originalsRemovedCount)")
                    ReceiptLine(label: "Originals still in library", value: "\(pending.count)",
                                detail: pending.isEmpty ? nil : "Kept until you approve removal. Keeping both is fine; it just doesn't free space.")
                    ReceiptLine(label: "Skipped", value: "\(summary.skipped.count)")
                    ReceiptLine(label: "Didn't work", value: "\(summary.failed.count)")
                    Rule()
                    ReceiptLine(label: "Net library reduction", value: "≈ \(Format.bytes(summary.estimatedReduction))", strong: true)
                    if summary.pendingReduction > 0 {
                        Text("Another ≈ \(Format.bytes(summary.pendingReduction)) if you remove the originals below.")
                            .font(.caption).foregroundStyle(Workshop.ink2)
                    }
                    Text("Counts what is gone from your library, not a measured iCloud figure. Items in Recently Deleted don't count toward iCloud storage; reporting can take time to update.")
                        .font(.caption).foregroundStyle(Workshop.ink3)
                }

                if !pending.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Silk("Your call")
                        Text("Smaller copy ready. Original still here.").font(.system(.headline, design: .rounded)).foregroundStyle(Workshop.ink)
                        Text("\(Format.count(pending.count, "original video")) can be removed because its smaller copy is verified. Nothing is removed unless you choose to. Removal applies on all your devices.")
                            .font(.footnote).foregroundStyle(Workshop.ink2)
                        ForEach(summary.copies.filter { !$0.originalRemoved }) { c in
                            HStack {
                                Text(model.title(for: c.original)).font(.footnote.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text("saves ≈ \(Format.bytes(c.savedBytes))").font(.system(.footnote, design: .monospaced))
                            }.foregroundStyle(Workshop.ink)
                        }
                        Button("Review \(Format.count(pending.count, "original")) for removal…") { confirmRemoval = true }
                            .buttonStyle(.chunky).disabled(model.isRemoving)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).workshopModule(radius: 20, screws: false)
                }

                ForEach(summary.skipped, id: \.id) { s in
                    Banner(symbol: "arrow.uturn.right.circle", tint: Workshop.ink2, text: "\(model.title(for: s.id)) was skipped: \(s.reason)")
                }
                ForEach(summary.failed, id: \.id) { f in
                    Banner(symbol: "exclamationmark.triangle", text: "\(model.title(for: f.id)) didn't work: \(f.message). The original was not touched; you can try again later.")
                }
                ForEach(summary.notes, id: \.self) { Banner(symbol: "info.circle", tint: Brand.blue, text: $0) }

                Text("Removed items are normally recoverable for 30 days, but not if your iCloud storage was over its limit.")
                    .font(.footnote).foregroundStyle(Workshop.ink2).multilineTextAlignment(.center)
                Button("How to recover in Photos") {
                    if let url = URL(string: "https://support.apple.com/108922") { openURL(url) }
                }.buttonStyle(.borderless)
                Button("Back to the bench") { model.finishRun() }.buttonStyle(.chunky).disabled(model.isRemoving)
            }
            .padding(22).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .background(BenchBackground())
        .confirmationDialog("Remove \(Format.count(pending.count, "original video"))?",
                            isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove originals", role: .destructive) { Task { await model.removeVideoOriginals() } }
            Button("Keep originals", role: .cancel) {}
        } message: {
            Text("The smaller copies stay. Originals are normally recoverable from Recently Deleted for 30 days, unless your iCloud storage is over its limit.")
        }
    }
}

#if DEBUG
#Preview("Plan receipt") {
    PreviewHost { PlanReceiptView() }
}
#Preview("Recap") {
    let id = MediaID("Beach day.mov")
    PreviewHost {
        RecapView(summary: RunSummary(removedCount: 12, removedBytes: 41_000_000,
                                      copies: [.init(original: id, copy: MediaID("copy"), savedBytes: 2_300_000_000)],
                                      skipped: [(MediaID("Ski run.mov"), "Already optimized")],
                                      failed: [], notes: []))
    }
}
#endif
