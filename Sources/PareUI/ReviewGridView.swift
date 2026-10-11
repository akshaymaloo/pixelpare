import PareCore
import SwiftUI

/// The light-table idea for ungrouped finds (old screenshots, blurry shots): a grid you mark photo by photo.
/// Nothing starts marked.
struct ReviewGridView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.calm) private var calm

    let title: String
    let blurb: String
    var details: String?
    let emptyTitle: String
    let emptyMessage: String
    let symbol: String
    let ids: [MediaID]
    let selected: Set<MediaID>
    let toggle: (MediaID) -> Void
    let selectAll: () -> Void
    let clear: () -> Void
    /// Optional small label on each card (size, duration…).
    var badge: ((MediaID) -> String?)?
    var idPrefix = "review"
    var markedValue = "Marked for removal"
    var cardHint = "Toggles the mark. Nothing is removed until you confirm the receipt."
    var header: AnyView?

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if ids.isEmpty {
                EmptyShelf(symbol: symbol, title: emptyTitle, message: emptyMessage)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(blurb).font(.callout).foregroundStyle(Workshop.ink2)
                        if let details {
                            DisclosureGroup("Details") {
                                Text(details).font(.footnote).foregroundStyle(Workshop.ink2)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                            }
                            .font(.footnote.weight(.semibold)).foregroundStyle(Workshop.ink).tint(Workshop.ink)
                        }
                        header
                        HStack {
                            Silk("\(selected.count) of \(ids.count) marked")
                            Spacer()
                            Button("Mark all") { selectAll() }.buttonStyle(.chunkyPlain).controlSize(.small)
                                .accessibilityIdentifier("\(idPrefix)-mark-all")
                                .disabled(ids.isEmpty || ids.allSatisfy(selected.contains))
                            Button("Clear") { clear() }.buttonStyle(.chunkyPlain).controlSize(.small).disabled(selected.isEmpty)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 100 : 150), spacing: 12)], spacing: 12) {
                            ForEach(ids, id: \.self) { id in card(id) }
                        }
                        .padding(14)
                        .background(LampSurface())
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Workshop.bezel))
                    }
                    .padding(compact ? 12 : 20)
                    .frame(maxWidth: 1100).frame(maxWidth: .infinity)
                }
            }
        }
        .background(BenchBackground())
        .safeAreaInset(edge: .bottom) { PlanBar() }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { CalmToggle() } }
    }

    private func card(_ id: MediaID) -> some View {
        let marked = selected.contains(id)
        return Button {
            Feedback.tick(calm: calm)
            toggle(id)
        } label: {
            VStack(spacing: 4) {
                PolaroidFrame(corner: 6, border: 5, bottom: 5) {
                    ThumbnailView(id: id, maxPixel: 360).aspectRatio(3 / 4, contentMode: .fit)
                        .saturation(marked ? 0.8 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if marked {
                        Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(Workshop.ink)
                            .padding(5).background(Circle().fill(Workshop.amber)).offset(x: 4, y: -4)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let text = badge?(id) {
                        Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Workshop.ink.opacity(0.78))).padding(8)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Workshop.amber, lineWidth: marked ? 3 : 0))
                .opacity(marked ? 0.85 : 1)
                .settle(value: marked)
                Text(Format.date(model.items[id]?.creationDate)).font(.caption2).foregroundStyle(Workshop.lampText).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.title(for: id)), \(Format.bytes(model.items[id]?.byteSize ?? 0))")
        .accessibilityIdentifier("\(idPrefix)-card")
        .accessibilityValue(marked ? markedValue : "Not marked")
        .accessibilityHint(cardHint)
    }
}

extension Workshop {
    static let lampText = Color(hex: 0x4A5A58)
}

struct LampSurface: View {
    var body: some View {
        LinearGradient(colors: [Workshop.lamp, Color(hex: 0xF5FBFA)], startPoint: .top, endPoint: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct ScreenshotsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ReviewGridView(
            title: "Old screenshots",
            blurb: "Screenshots older than 30 days, tied up for later. They aren't automatically worthless: mark only the ones you're sure about.",
            emptyTitle: "No old screenshots", emptyMessage: "No screenshots older than 30 days were found.",
            symbol: "iphone", ids: model.screenshotIDs, selected: model.selectedScreenshots,
            toggle: { model.toggleScreenshot($0) }, selectAll: { model.selectAllScreenshots() },
            clear: { model.clearScreenshots() })
    }
}

struct BlurryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ReviewGridView(
            title: "Blurry shots",
            blurb: "Very soft photos that aren't part of a lookalike group. Some are blurry on purpose, so look before you mark. Favorites never appear here.",
            emptyTitle: "No blurry shots", emptyMessage: "No very soft photos were found.",
            symbol: "camera.metering.unknown", ids: model.blurryIDs, selected: model.selectedBlurry,
            toggle: { model.toggleBlurry($0) }, selectAll: { model.selectAllBlurry() },
            clear: { model.clearBlurry() })
    }
}

struct RecordingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ReviewGridView(
            title: "Screen recordings",
            blurb: "Screen recordings older than 30 days, biggest first. They're often long and forgotten. Mark only the ones you're sure about; they go to Recently Deleted. Favorites never appear here.",
            emptyTitle: "No old screen recordings", emptyMessage: "No screen recordings older than 30 days were found.",
            symbol: "record.circle", ids: model.screenRecordingIDs, selected: model.selectedRecordings,
            toggle: { model.toggleRecording($0) }, selectAll: { model.selectAllRecordings() },
            clear: { model.clearRecordings() },
            badge: { id in
                guard let item = model.items[id] else { return nil }
                return [item.byteSize.map(Format.bytes), item.duration.map(Format.duration)].compactMap { $0 }.joined(separator: " · ")
            },
            idPrefix: "recordings")
    }
}

struct LivePhotosView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let unfinished = model.unfinishedStillIDs.intersection(model.livePhotoIDs)
        ReviewGridView(
            title: "Live Photos",
            blurb: "Turn Live Photos into still photos and drop the motion clip (about 2–4 MB each). The still keeps date, place, favorite and albums.",
            details: "Motion and sound are lost, along with any Loop, Bounce or Long Exposure effect. The Live Photo goes to Recently Deleted only after the still is verified. Edited Live Photos aren't offered.",
            emptyTitle: "No Live Photos to convert", emptyMessage: "No unedited Live Photos were found.",
            symbol: "livephoto", ids: model.livePhotoIDs, selected: model.selectedStills,
            toggle: { model.toggleStill($0) }, selectAll: { model.selectAllStills() },
            clear: { model.clearStills() },
            badge: { id in
                guard let item = model.items[id] else { return nil }
                let saves = item.pairedVideoBytes.map { "−" + Format.bytes($0) } ?? ""
                return item.isFavorite ? "♥ " + saves : saves
            },
            idPrefix: "live", markedValue: "Marked to make a still",
            cardHint: "Toggles the mark. Nothing changes until you confirm the receipt.",
            header: unfinished.isEmpty ? nil : AnyView(
                HStack {
                    Banner(symbol: "arrow.triangle.2.circlepath",
                           text: "\(Format.count(unfinished.count, "conversion")) didn't finish last time. Finishing reuses the still that was already made.")
                    Button("Mark them") { model.selectUnfinishedStills() }.buttonStyle(.chunkyPlain).controlSize(.small)
                }))
    }
}

#if DEBUG
#Preview("Screenshots") { PreviewHost { NavigationStack { ScreenshotsView() } } }
#Preview("Blurry") { PreviewHost { NavigationStack { BlurryView() } } }
#endif
