import PareCore
import SwiftUI

private func kindName(_ item: MediaItem) -> String {
    switch item.kind {
    case .video: item.isScreenRecording ? "Screen recording" : "Video"
    case .livePhoto: "Live Photo"
    case .screenshot: "Screenshot"
    case .photo: "Photo"
    }
}

/// The largest things in the library, biggest first. Each row can be pressed (videos) or marked for removal.
struct BiggestView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.calm) private var calm

    var body: some View {
        Group {
            if model.biggestIDs.isEmpty {
                EmptyShelf(symbol: "scalemass", title: "Nothing huge", message: "No single photo or video is large enough to stand out.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The \(model.biggestIDs.count) biggest items, \(Format.bytes(model.biggestBytes)) together. Videos can be pressed into a smaller copy. Any item can be marked for removal; it goes to Recently Deleted. Favorites can't be marked.")
                            .font(.callout).foregroundStyle(Workshop.ink2)
                        Silk("\(model.selectedBiggest.count) of \(model.biggestIDs.count) marked")
                        VStack(spacing: 0) {
                            ForEach(model.biggestIDs, id: \.self) { id in
                                row(id)
                                if id != model.biggestIDs.last { Divider() }
                            }
                        }
                        .padding(14).workshopModule(radius: 20, screws: false)
                    }
                    .padding(14).frame(maxWidth: 900).frame(maxWidth: .infinity)
                }
            }
        }
        .background(BenchBackground())
        .safeAreaInset(edge: .bottom) { PlanBar() }
        .navigationTitle("Biggest things")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { CalmToggle() } }
    }

    private func row(_ id: MediaID) -> some View {
        let item = model.items[id]
        let marked = model.selectedBiggest.contains(id)
        let favorite = item?.isFavorite == true
        return HStack(spacing: 12) {
            PolaroidFrame(corner: 4, border: 3, bottom: 3) { ThumbnailView(id: id, maxPixel: 160).frame(width: 52, height: 52) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title(for: id)).font(.subheadline.weight(.semibold)).foregroundStyle(Workshop.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Chip(text: item.map(kindName) ?? "Item")
                    if favorite { Chip(text: "Favorite", color: Workshop.amberDark) }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Format.bytes(item?.byteSize ?? 0)).font(.system(.headline, design: .monospaced, weight: .bold))
                    .foregroundStyle(Workshop.ink)
                HStack(spacing: 6) {
                    if model.canPress(id) {
                        Button("Press") { model.pressFromBiggest(id) }.buttonStyle(.chunkyPlain).controlSize(.small)
                            .accessibilityIdentifier("biggest-press")
                    }
                    Button(marked ? "Unmark" : "Mark") { Feedback.tick(calm: calm); model.toggleBiggest(id) }
                        .buttonStyle(.chunkyPlain).controlSize(.small).disabled(favorite)
                        .accessibilityIdentifier("biggest-mark")
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 8)
        .opacity(marked ? 0.85 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.title(for: id)), \(item.map(kindName) ?? "item"), \(Format.bytes(item?.byteSize ?? 0))")
        .accessibilityValue(marked ? "Marked for removal" : "Not marked")
    }
}

/// Bursts with a kept pick and the frames nobody picked.
struct BurstsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.calm) private var calm

    var body: some View {
        Group {
            if model.burstGroups.isEmpty {
                EmptyShelf(symbol: "square.stack.3d.down.right", title: "No burst leftovers",
                           message: "No bursts with unpicked frames were found.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Each burst keeps the frame you (or the camera) picked. The other frames are suggestions: nothing is marked until you do it, and favorites are always kept.")
                            .font(.callout).foregroundStyle(Workshop.ink2)
                        HStack {
                            Silk("\(model.selectedBursts.count) of \(model.burstLeftoverIDs.count) frames marked")
                            Spacer()
                            Button("Mark all") { model.selectAllBursts() }.buttonStyle(.chunkyPlain).controlSize(.small)
                                .disabled(model.burstLeftoverIDs.allSatisfy(model.selectedBursts.contains))
                                .accessibilityIdentifier("bursts-mark-all")
                            Button("Clear") { model.clearBursts() }.buttonStyle(.chunkyPlain).controlSize(.small)
                                .disabled(model.selectedBursts.isEmpty)
                        }
                        ForEach(model.burstGroups) { g in burst(g) }
                    }
                    .padding(14).frame(maxWidth: 900).frame(maxWidth: .infinity)
                }
            }
        }
        .background(BenchBackground())
        .safeAreaInset(edge: .bottom) { PlanBar() }
        .navigationTitle("Burst leftovers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .primaryAction) { CalmToggle() } }
    }

    private func burst(_ g: BurstGroup) -> some View {
        let all = g.leftovers.allSatisfy(model.selectedBursts.contains)
        let bytes = g.leftovers.reduce(Int64(0)) { $0 + (model.items[$1]?.byteSize ?? 0) }
        let date = (g.picks + g.leftovers).compactMap { model.items[$0]?.creationDate }.min()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Burst · \(Format.date(date))").font(.system(.headline, design: .rounded)).foregroundStyle(Workshop.ink)
                    Text("Keeps \(g.picks.count == 1 ? "1 pick" : "\(g.picks.count) picks"), \(Format.count(g.leftovers.count, "extra frame")) · \(Format.bytes(bytes))")
                        .font(.footnote).foregroundStyle(Workshop.ink2)
                }
                Spacer()
                Button(all ? "Unmark extras" : "Mark \(g.leftovers.count) extras") { Feedback.tick(calm: calm); model.toggleBurst(g) }
                    .buttonStyle(.chunkyPlain).controlSize(.small)
                    .accessibilityIdentifier("burst-approve")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(g.picks, id: \.self) { frame($0, pick: true) }
                    ForEach(g.leftovers, id: \.self) { frame($0, pick: false) }
                }.padding(.vertical, 4)
            }
        }
        .padding(16).workshopModule(radius: 20, screws: false)
    }

    private func frame(_ id: MediaID, pick: Bool) -> some View {
        let marked = model.selectedBursts.contains(id)
        return Button {
            Feedback.tick(calm: calm)
            model.toggleBurstFrame(id)
        } label: {
            PolaroidFrame(corner: 6, border: 4, bottom: 4) {
                ThumbnailView(id: id, maxPixel: 240).frame(width: 84, height: 100)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: pick ? "star.fill" : (marked ? "bookmark.fill" : "circle.dashed"))
                    .font(.caption2).foregroundStyle(pick ? Workshop.ink : Workshop.ink)
                    .padding(4).background(Circle().fill(pick ? Brand.teal : (marked ? Workshop.amber : Workshop.paper)))
                    .offset(x: 4, y: -4)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Workshop.amber, lineWidth: marked ? 3 : 0))
            .opacity(marked ? 0.85 : 1)
        }
        .buttonStyle(.plain).disabled(pick)
        .accessibilityIdentifier(pick ? "burst-pick" : "burst-frame")
        .accessibilityLabel(pick ? "Kept pick" : "Extra frame, \(Format.bytes(model.items[id]?.byteSize ?? 0))")
        .accessibilityValue(pick ? "Always kept" : (marked ? "Marked for removal" : "Not marked"))
    }
}

#if DEBUG
#Preview("Biggest") { PreviewHost { NavigationStack { BiggestView() } } }
#Preview("Bursts") { PreviewHost { NavigationStack { BurstsView() } } }
#endif
