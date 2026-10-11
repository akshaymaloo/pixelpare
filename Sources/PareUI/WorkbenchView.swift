import PareCore
import SwiftUI

/// Home: the workbench, with one tray per kind of find.
struct WorkbenchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { sizeClass == .compact }
    private var scanning: Bool { if case .scanning = model.scanState { true } else { false } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if case .scanning(let p) = model.scanState { scanningCard(p) }
                if case .failed(let message) = model.scanState {
                    Banner(symbol: "exclamationmark.triangle", text: "The scan stopped: \(message)")
                }
                if model.pendingApprovalCount > 0 { pendingCopies }
                if model.scanState == .ready { trays }
            }
            .padding(compact ? 14 : 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            guard !scanning else { return }
            model.rescan()
            await Task.yield()
            while scanning, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        }
        .background(BenchBackground())
        .safeAreaInset(edge: .bottom) { if !model.plan.isEmpty { PlanBar() } }
        .navigationTitle("Workbench")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let last = model.lastScan, !compact {
                    Text("Last scan · \(last.formatted(.relative(presentation: .numeric)))")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(Workshop.ink2)
                        .lineLimit(1)
                }
                CalmToggle()
                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(scanning)
                Menu {
                    Button { model.path.append(.history) } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    Button { model.path.append(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
    }

    // MARK: Header

    private var headlineFont: Font { .system(compact ? .title : .largeTitle, design: .rounded, weight: .heavy) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Silk("Workbench · \(model.librarySummary)")
            if model.scanState == .ready {
                let r = model.opportunity
                if r.upperBound > 0 {
                    Text("About \(Format.range(r)) worth a look").font(headlineFont).foregroundStyle(Workshop.ink)
                    Text("Photos plus videos pressed at \(model.preset.title). An estimate: nothing is marked yet, and nothing is removed until you approve it.")
                        .font(.callout).foregroundStyle(Workshop.ink2)
                } else {
                    Text("Your library looks tidy").font(headlineFont).foregroundStyle(Workshop.ink)
                    Text("Nothing worth a look right now.").font(.callout).foregroundStyle(Workshop.ink2)
                }
            } else {
                Text("Let's make some room").font(headlineFont).foregroundStyle(Workshop.ink)
            }
        }
    }

    private func scanningCard(_ p: ScanProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Silk("Scanning")
            Text(p.message).font(.system(.headline, design: .rounded)).foregroundStyle(Workshop.ink)
            if p.phase == .analyzing { ProgressView(value: p.fraction).tint(Brand.teal) }
            else { ProgressView().tint(Brand.teal) }
            HStack {
                Text("Works from small thumbnails on this device.")
                    .font(.footnote).foregroundStyle(Workshop.ink2)
                Spacer()
                Button("Stop") { model.cancelScan() }.buttonStyle(.chunkyPlain).controlSize(.small)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .workshopModule()
    }

    private var pendingCopies: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.seal").font(.title2).foregroundStyle(Brand.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.count(model.pendingApprovalCount, "smaller copy", "smaller copies")) ready")
                    .font(.system(.headline, design: .rounded)).foregroundStyle(Workshop.ink)
                Text("Verified and in your library. The originals stay until you approve removing them.")
                    .font(.footnote).foregroundStyle(Workshop.ink2)
            }
            Spacer()
            Button("Review originals") { model.reviewPendingOriginals() }.buttonStyle(.chunkyPlain)
        }
        .padding(16).workshopModule(radius: 20)
    }

    // MARK: Trays

    private var trays: some View {
        let columns = [GridItem(.adaptive(minimum: compact ? 300 : 440), spacing: 18, alignment: .top)]
        return LazyVGrid(columns: columns, spacing: 18) {
            LookalikeTray()
            VideoPressTray()
            ScreenshotTray()
            BlurryTray()
            RecordingsTray()
            BiggestTray()
            BurstTray()
            LiveTray()
            GaugeCard()
        }
    }
}

private struct TrayShell<Content: View>: View {
    let label: String
    var trailing = ""
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Silk(label); Spacer(); Silk(trailing, color: Workshop.ink3) }
                .padding(.top, 6)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workshopModule()
    }
}

private func trayTitle(_ text: String) -> some View {
    Text(text).font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
}

private struct LookalikeTray: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var hovering = false

    var body: some View {
        let groups = model.sortedGroups
        let preview = groups.first?.members ?? []
        TrayShell(label: "Module 01 · Lookalike tray", trailing: "Photos") {
            if groups.isEmpty {
                empty
            } else {
                let layout = sizeClass == .compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                                   : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Let's make some room.").font(.callout).foregroundStyle(Workshop.ink)
                        Text("\(groups.count)")
                            .font(.system(size: 58, weight: .heavy, design: .rounded)).foregroundStyle(Workshop.ink)
                        Text(groups.count == 1 ? "group to look at" : "groups to look at")
                            .font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink2)
                        Text("These shots belong together. Each group opens on the light table. Nothing is marked until you do it.")
                            .font(.footnote).foregroundStyle(Workshop.ink2)
                        HStack {
                            Button("Open the tray") { model.path.append(.similar) }.buttonStyle(.chunky)
                            Silk("\(model.approvedGroupCount) approved", color: Workshop.ink3)
                        }
                        .padding(.top, 6)
                    }
                    FannedCards(ids: preview, lifted: hovering)
                        .frame(maxWidth: .infinity, minHeight: 150)
                        .padding(.top, 14)
                }
            }
        }
        .onHover { hovering = $0 }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            trayTitle("No lookalikes")
            Text("No groups of near-identical photos were found.").font(.callout).foregroundStyle(Workshop.ink2)
            if model.unanalyzedCount > 0 {
                Text("\(Format.count(model.unanalyzedCount, "photo")) couldn't be looked at yet (iCloud only).")
                    .font(.footnote).foregroundStyle(Workshop.ink3)
            }
        }.frame(minHeight: 120, alignment: .leading)
    }
}

private struct VideoPressTray: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let count = model.eligibleVideoIDs.count
        TrayShell(label: "Module 02 · Video press", trailing: "Videos") {
            if count == 0 {
                VStack(alignment: .leading, spacing: 6) {
                    trayTitle("No videos to press")
                    Text("Nothing large enough to be worth a smaller copy.").font(.callout).foregroundStyle(Workshop.ink2)
                }.frame(minHeight: 120, alignment: .leading)
            } else {
                HStack(spacing: 16) {
                    ReelIcon(spinning: hovering).padding(4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(count)").font(.system(size: 52, weight: .heavy, design: .rounded)).foregroundStyle(Workshop.ink)
                        Text(count == 1 ? "video could travel lighter" : "videos could travel lighter")
                            .font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink2)
                    }
                }
                Text("Make smaller copies of big videos. Your original stays until the copy is checked and you say so.")
                    .font(.footnote).foregroundStyle(Workshop.ink2)
                HStack {
                    Button("Open the press") { model.path.append(.videos) }.buttonStyle(.chunky)
                    Chip(text: "Sizes are estimates", color: Workshop.amberDark)
                }
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct ScreenshotTray: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.screenshotIDs
        TrayShell(label: "Module 03 · Old screenshots", trailing: "Photos") {
            if ids.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    trayTitle("Old screenshots")
                    Text("No screenshots older than 30 days.").font(.callout).foregroundStyle(Workshop.ink2)
                }.frame(minHeight: 100, alignment: .leading)
            } else {
                HStack(spacing: 16) {
                    BundleStack(ids: Array(ids.prefix(3)))
                    VStack(alignment: .leading, spacing: 6) {
                        trayTitle("Old screenshots")
                        Text("\(Format.count(ids.count, "screenshot")) older than 30 days, about \(Format.range(model.screenshotOpportunity)). Not automatically worthless. You open the bundle, you decide.")
                            .font(.footnote).foregroundStyle(Workshop.ink2)
                        Button("Untie the bundle") { model.path.append(.screenshots) }.buttonStyle(.chunkyPlain)
                    }
                }
            }
        }
    }
}

private struct BlurryTray: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.blurryIDs
        TrayShell(label: "Module 04 · Blurry shots", trailing: "Photos") {
            if ids.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    trayTitle("Blurry shots")
                    Text("No very soft photos found.").font(.callout).foregroundStyle(Workshop.ink2)
                }.frame(minHeight: 100, alignment: .leading)
            } else {
                HStack(spacing: 16) {
                    BundleStack(ids: Array(ids.prefix(3)), tied: false)
                    VStack(alignment: .leading, spacing: 6) {
                        trayTitle("Blurry shots")
                        Text("\(Format.count(ids.count, "very soft photo")), about \(Format.range(model.blurryOpportunity)). Some are blurry on purpose. Look before you mark.")
                            .font(.footnote).foregroundStyle(Workshop.ink2)
                        Button("Take a look") { model.path.append(.blurry) }.buttonStyle(.chunkyPlain)
                    }
                }
            }
        }
    }
}

/// The shared look of the simple "bundle + blurb + button" trays.
private struct BundleTray: View {
    let label: String
    let trailing: String
    let title: String
    let emptyText: String
    let ids: [MediaID]
    let text: String
    let button: String
    let destination: Destination
    let identifier: String
    var tied = false
    @Environment(AppModel.self) private var model

    var body: some View {
        TrayShell(label: label, trailing: trailing) {
            if ids.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    trayTitle(title)
                    Text(emptyText).font(.callout).foregroundStyle(Workshop.ink2)
                }.frame(minHeight: 100, alignment: .leading)
            } else {
                HStack(spacing: 16) {
                    BundleStack(ids: Array(ids.prefix(3)), tied: tied)
                    VStack(alignment: .leading, spacing: 6) {
                        trayTitle(title)
                        Text(text).font(.footnote).foregroundStyle(Workshop.ink2)
                        Button(button) { model.path.append(destination) }.buttonStyle(.chunkyPlain)
                            .accessibilityIdentifier(identifier)
                    }
                }
            }
        }
    }
}

private struct RecordingsTray: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let ids = model.screenRecordingIDs
        BundleTray(label: "Module 05 · Screen recordings", trailing: "Videos", title: "Screen recordings",
                   emptyText: "No screen recordings older than 30 days.", ids: ids,
                   text: "\(Format.count(ids.count, "old screen recording")), about \(Format.range(model.recordingOpportunity)). Long and easy to forget. You pick which go.",
                   button: "See recordings", destination: .recordings, identifier: "tray-recordings")
    }
}

private struct BiggestTray: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let ids = model.biggestIDs
        BundleTray(label: "Module 06 · Biggest things", trailing: "Everything", title: "Biggest things",
                   emptyText: "Nothing is big enough to stand out.", ids: ids,
                   text: "The \(ids.count) largest items, \(Format.bytes(model.biggestBytes)) together. Press a video or mark what you don't need.",
                   button: "Weigh them", destination: .biggest, identifier: "tray-biggest")
    }
}

private struct BurstTray: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let groups = model.burstGroups
        let ids = groups.compactMap(\.picks.first)
        BundleTray(label: "Module 07 · Burst leftovers", trailing: "Photos", title: "Burst leftovers",
                   emptyText: "No bursts with unpicked frames.", ids: ids,
                   text: "\(Format.count(model.burstLeftoverIDs.count, "extra frame")) in \(Format.count(groups.count, "burst")), about \(Format.range(model.burstOpportunity)). Your picks stay.",
                   button: "Sort the bursts", destination: .bursts, identifier: "tray-bursts", tied: true)
    }
}

private struct LiveTray: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let ids = model.livePhotoIDs
        BundleTray(label: "Module 08 · Live Photos", trailing: "Photos", title: "Live Photos to stills",
                   emptyText: "No Live Photos to convert.", ids: ids,
                   text: "\(Format.count(ids.count, "Live Photo")) could shed their motion clip, about \(Format.range(model.liveOpportunity)). The still is verified first; the motion is lost.",
                   button: "Make stills", destination: .livePhotos, identifier: "tray-live")
    }
}

private struct BundleStack: View {
    let ids: [MediaID]
    var tied = true

    var body: some View {
        ZStack {
            ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                PolaroidFrame(corner: 6, border: 5, bottom: 5) {
                    ThumbnailView(id: id, maxPixel: 220).frame(width: 58, height: 84)
                }
                .rotationEffect(.degrees(Double(i - 1) * 8))
                .offset(x: Double(i - 1) * 14)
            }
            if tied {
                Rectangle().fill(Color(hex: 0xD9534F)).frame(width: 110, height: 3).rotationEffect(.degrees(-10))
                Rectangle().fill(Color(hex: 0xD9534F)).frame(width: 110, height: 3).rotationEffect(.degrees(24))
            }
        }
        .frame(width: 120, height: 110)
        .accessibilityHidden(true)
    }
}

private struct GaugeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let r = model.opportunity
        let maxValue = Self.niceMax(r.upperBound)
        TrayShell(label: "Gauge · Honest estimate") {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
            layout {
                RangeGauge(low: r.lowerBound, high: r.upperBound, maxValue: maxValue)
                    .frame(width: 190, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Could free about").font(.system(.callout, design: .monospaced, weight: .semibold)).foregroundStyle(Workshop.ink)
                    Text("\(Format.range(r)) · estimate")
                        .font(.system(.callout, design: .monospaced, weight: .bold)).foregroundStyle(Workshop.ink)
                    Text("Counts each item once and subtracts the size of the new copies. A net library change, not a measured iCloud figure. Video savings only count once an original is removed.")
                        .font(.footnote).foregroundStyle(Workshop.ink2)
                }
            }
        }
    }

    static func niceMax(_ bytes: Int64) -> Int64 {
        let gb: Int64 = 1_000_000_000
        let target = Double(bytes) * 1.2
        let steps: [Int64] = [1, 2, 5, 10, 15, 20, 50, 100, 200, 500, 1000, 2000]
        return (steps.first { Double($0 * gb) >= target } ?? 2000) * gb
    }
}

#if DEBUG
#Preview("Workbench") {
    PreviewHost { NavigationStack { WorkbenchView() } }
}
#endif
