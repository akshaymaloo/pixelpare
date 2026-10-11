import SwiftUI

/// All in-app help text lives here, keyed by screen. Edit words in this one file.
struct HelpItem: Hashable {
    let icon: String
    let label: String
    let meaning: String
}

struct HelpTopic {
    let icon: String
    let title: String
    let summary: String
    let finds: String
    let buttons: [HelpItem]
}

struct WelcomeCard: Hashable {
    let icon: String
    let title: String
    let text: String
}

enum HelpContent {
    static let safeLine = "Nothing is removed until you review it. Removed items wait in Recently Deleted for 30 days. Favorites are never removed. Video originals go only after you approve the checked copy."

    static func topic(for d: Destination) -> HelpTopic {
        switch d {
        case .home:
            HelpTopic(icon: "square.grid.2x2", title: "Workbench", summary: "Your starting point",
                      finds: "Shows every way PixelPare can free space, with a rough saving for each.",
                      buttons: [
                        HelpItem(icon: "rectangle.stack", label: "Open a tray", meaning: "Opens that cleanup tool."),
                        HelpItem(icon: "leaf", label: "Calm", meaning: "Turns off animation, sound and haptics."),
                        HelpItem(icon: "arrow.clockwise", label: "Rescan", meaning: "Looks through your library again."),
                        HelpItem(icon: "ellipsis.circle", label: "More", meaning: "Opens History and Settings."),
                        HelpItem(icon: "stop.circle", label: "Stop", meaning: "Stops a scan that is running."),
                        HelpItem(icon: "checkmark.seal", label: "Review originals", meaning: "Appears when a checked smaller copy is ready. You decide about its original."),
                      ])
        case .similar:
            HelpTopic(icon: "square.on.square", title: "Lookalike tray", summary: "Near-duplicate photos",
                      finds: "Groups photos that are nearly the same shot and suggests which to keep.",
                      buttons: [
                        HelpItem(icon: "bookmark", label: "Mark / Undo", meaning: "Mark a photo for removal, or put it back."),
                        HelpItem(icon: "star", label: "Make keeper", meaning: "Picks the photo that always stays."),
                        HelpItem(icon: "forward", label: "Skip", meaning: "Decide about this group later."),
                        HelpItem(icon: "checkmark.circle", label: "Keep group", meaning: "Keeps every photo in the group."),
                        HelpItem(icon: "checkmark.circle.fill", label: "Approve group", meaning: "Adds the marked photos to your plan."),
                        HelpItem(icon: "arrow.up.arrow.down", label: "Sort", meaning: "Orders groups by date or size."),
                        HelpItem(icon: "receipt", label: "Review receipt", meaning: "Shows the whole plan before anything happens."),
                        HelpItem(icon: "hand.tap", label: "Long-press · double-tap · swipe", meaning: "Long-press to peek. Double-tap to make keeper. Swipe up to mark, down to undo."),
                      ])
        case .videos:
            HelpTopic(icon: "film.stack", title: "Video press", summary: "Smaller copies of big videos",
                      finds: "Makes smaller copies of large videos, then checks they play the same.",
                      buttons: [
                        HelpItem(icon: "dial.medium", label: "Gentle · Balanced · Compact", meaning: "How much smaller. Gentle keeps the most quality; Compact saves the most."),
                        HelpItem(icon: "checklist", label: "Select all / Clear", meaning: "Picks or unpicks every video in the list."),
                        HelpItem(icon: "eye", label: "Eye", meaning: "Makes a short sample so you can check quality first."),
                        HelpItem(icon: "receipt", label: "Review", meaning: "Shows the plan. Nothing starts until you confirm."),
                      ])
        case .screenshots:
            HelpTopic(icon: "iphone", title: "Old screenshots", summary: "Screenshots over 30 days old",
                      finds: "Collects screenshots older than 30 days that you may not need.",
                      buttons: reviewButtons)
        case .blurry:
            HelpTopic(icon: "camera.metering.unknown", title: "Blurry shots", summary: "Very soft photos",
                      finds: "Finds very soft photos. Some are blurry on purpose, so look first.",
                      buttons: reviewButtons)
        case .recordings:
            HelpTopic(icon: "record.circle", title: "Screen recordings", summary: "Old recordings, biggest first",
                      finds: "Lists screen recordings older than 30 days, biggest first.",
                      buttons: reviewButtons)
        case .biggest:
            HelpTopic(icon: "scalemass", title: "Biggest things", summary: "Your largest photos and videos",
                      finds: "Lists your largest items so you can spot what takes the most room.",
                      buttons: [
                        HelpItem(icon: "checkmark.circle", label: "Row", meaning: "Tap an item to mark or unmark it. Favorites can't be marked."),
                        HelpItem(icon: "film.stack", label: "Press", meaning: "Makes a smaller copy of that video instead of removing it."),
                        HelpItem(icon: "receipt", label: "Review receipt", meaning: "Shows the whole plan before anything happens."),
                      ])
        case .bursts:
            HelpTopic(icon: "square.stack.3d.down.right", title: "Burst leftovers", summary: "Extra frames from bursts",
                      finds: "Finds the frames nobody picked in burst shots. The picked frame stays.",
                      buttons: [
                        HelpItem(icon: "checkmark.circle", label: "Mark N extras", meaning: "Marks the leftover frames of one burst. Tap again to undo."),
                        HelpItem(icon: "checklist", label: "Mark all / Clear", meaning: "Marks or unmarks every leftover frame."),
                        HelpItem(icon: "receipt", label: "Review receipt", meaning: "Shows the whole plan before anything happens."),
                      ])
        case .livePhotos:
            HelpTopic(icon: "livephoto", title: "Live Photos", summary: "Turn motion into stills",
                      finds: "Turns Live Photos into plain stills, dropping the short motion clip.",
                      buttons: reviewButtons + [
                        HelpItem(icon: "arrow.triangle.2.circlepath", label: "Mark them", meaning: "Marks conversions that didn't finish last time."),
                      ])
        case .history:
            HelpTopic(icon: "clock.arrow.circlepath", title: "History", summary: "What happened to your videos",
                      finds: "Lists videos you pressed and where each one stands.",
                      buttons: [
                        HelpItem(icon: "list.bullet", label: "Each row", meaning: "Shows the video, its step and the time. Orange text explains a problem."),
                      ])
        case .settings:
            HelpTopic(icon: "gearshape", title: "Settings", summary: "Library and options",
                      finds: "Choose the library, rescan, and review how PixelPare stays safe.",
                      buttons: [
                        HelpItem(icon: "arrow.clockwise", label: "Scan again", meaning: "Looks through your library again."),
                        HelpItem(icon: "wifi", label: "Download videos over cellular", meaning: "Off means pressing waits for Wi‑Fi."),
                        HelpItem(icon: "sparkles", label: "Show welcome again", meaning: "Replays the three intro cards."),
                      ])
        }
    }

    private static let reviewButtons: [HelpItem] = [
        HelpItem(icon: "photo", label: "Tap a photo", meaning: "Marks it for removal. Tap again to unmark."),
        HelpItem(icon: "checklist", label: "Mark all / Clear", meaning: "Marks or unmarks every photo here."),
        HelpItem(icon: "receipt", label: "Review receipt", meaning: "Shows the whole plan before anything happens."),
    ]

    /// Features listed in Settings → "What can PixelPare do?", in Workbench order.
    static let features: [Destination] = [.similar, .videos, .screenshots, .blurry, .recordings, .biggest, .bursts, .livePhotos, .history]

    static let welcome: [WelcomeCard] = [
        WelcomeCard(icon: "wand.and.stars", title: "Free up iCloud space",
                    text: "PixelPare finds lookalikes, old screenshots, big videos and more. You pick what goes."),
        WelcomeCard(icon: "lock.shield", title: "Safe by design",
                    text: "Nothing is removed until you review it. Removed items wait 30 days in Recently Deleted. Favorites stay."),
        WelcomeCard(icon: "questionmark.circle", title: "Start anywhere",
                    text: "Open any tray from the Workbench. Tap ? on any screen to see what its buttons do."),
    ]
}

/// Short hint strings reused as macOS tooltips and VoiceOver hints.
enum Hint {
    static let rescan = "Look through your library again"
    static let more = "Open History and Settings"
    static let stopScan = "Stop the scan"
    static let reviewOriginals = "Decide about originals whose smaller copy is ready"
    static let openTray = "Open this cleanup tool"
    static let skip = "Decide about this group later"
    static let keepGroup = "Keep every photo in this group"
    static let approve = "Add the marked photos to your plan"
    static let undoApproval = "Take this group out of your plan"
    static let makeKeeper = "Make this the photo that always stays"
    static let sort = "Order groups by date or size"
    static let reviewReceipt = "Show the whole plan. Nothing is removed yet"
    static let selectAll = "Pick every video in the list"
    static let clear = "Unpick everything"
    static let markAll = "Mark everything on this screen"
    static let clearMarks = "Remove all marks"
    static let pressReview = "Show the plan. Nothing starts until you confirm"
    static let checkQuality = "Make a short sample to check quality"
    static let preset = "Choose how much smaller the copies are"
    static let pressFromBiggest = "Make a smaller copy instead of removing"
    static let markBurst = "Mark the extra frames of this burst"
    static let markUnfinished = "Mark conversions that didn't finish"
    static let resume = "Include this unfinished video in the next run"
    static let discard = "Forget this unfinished video"
    static let pause = "Pause; originals are untouched"
    static let backToBench = "Return to the Workbench"
    static let help = "What this screen does"
}

extension View {
    /// macOS tooltip plus VoiceOver hint from one string.
    func hint(_ text: String) -> some View {
        self.help(text).accessibilityHint(text)
    }
}

// MARK: Views

/// "?" toolbar button that opens the help sheet for a screen.
struct HelpButton: View {
    let topic: Destination
    @State private var showing = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { showing = true } label: { Label("Help", systemImage: "questionmark.circle").labelStyle(.iconOnly) }
            .accessibilityLabel("Help")
            .accessibilityIdentifier("help-button")
            .hint(Hint.help)
            .sheet(isPresented: $showing) {
                HelpSheet(topic: topic).environment(model)
            }
    }
}

struct HelpSheet: View {
    let topic: Destination
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let t = HelpContent.topic(for: topic)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: t.icon).font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 48, height: 48).background(Circle().fill(Brand.gradient))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(t.title) help").font(.system(.title2, design: .rounded, weight: .heavy))
                                .foregroundStyle(Workshop.ink).accessibilityIdentifier("help-title")
                                .accessibilityAddTraits(.isHeader)
                            Text(t.summary).font(.subheadline).foregroundStyle(Workshop.ink2)
                        }
                    }
                    section("What this finds") { Text(t.finds).font(.body).foregroundStyle(Workshop.ink) }
                    section("Buttons") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(t.buttons, id: \.self) { b in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: b.icon).foregroundStyle(Brand.teal).frame(width: 24)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(b.label).font(.subheadline.weight(.bold)).foregroundStyle(Workshop.ink)
                                        Text(b.meaning).font(.subheadline).foregroundStyle(Workshop.ink2)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    section("Safe by design") {
                        Label { Text(HelpContent.safeLine).font(.subheadline).foregroundStyle(Workshop.ink) }
                            icon: { Image(systemName: "lock.shield.fill").foregroundStyle(Brand.teal) }
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(BenchBackground())
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("help-done") }
            }
        }
        .preferredColorScheme(.light)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 460, idealWidth: 480, minHeight: 520)
        #endif
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Silk(title)
            content()
        }
    }
}

/// Three short cards shown on first launch and from Settings → "Show welcome again".
struct WelcomeView: View {
    let onDone: () -> Void
    @State private var page = 0
    private let cards = HelpContent.welcome

    var body: some View {
        let card = cards[page]
        let last = page == cards.count - 1
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ReelIcon(spinning: false, size: 64)
            Image(systemName: card.icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(Brand.teal)
                .accessibilityHidden(true)
            Text(card.title).font(.system(.title, design: .rounded, weight: .heavy)).foregroundStyle(Workshop.ink)
                .multilineTextAlignment(.center).accessibilityIdentifier("welcome-title")
            Text(card.text).font(.body).foregroundStyle(Workshop.ink2).multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                ForEach(cards.indices, id: \.self) { i in
                    Circle().fill(i == page ? Brand.teal : Workshop.ink3.opacity(0.5)).frame(width: 8, height: 8)
                }
            }
            .accessibilityElement().accessibilityLabel("Card \(page + 1) of \(cards.count)")
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if page > 0 {
                    Button("Back") { page -= 1 }.buttonStyle(.chunkyPlain).accessibilityIdentifier("welcome-back")
                }
                Button(last ? "Let's go" : "Next") { if last { onDone() } else { page += 1 } }
                    .buttonStyle(.chunky).accessibilityIdentifier("welcome-next")
            }
            if !last {
                Button("Skip") { onDone() }.buttonStyle(.borderless).foregroundStyle(Workshop.ink2)
                    .accessibilityIdentifier("welcome-skip")
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BenchBackground())
        .preferredColorScheme(.light)
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

/// Settings page: every feature with an icon and one line; tapping opens its help.
struct FeatureListView: View {
    @State private var selected: Destination?
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(HelpContent.features, id: \.self) { d in
                    let t = HelpContent.topic(for: d)
                    Button { selected = d } label: {
                        HStack(spacing: 12) {
                            Image(systemName: t.icon).foregroundStyle(Brand.teal).frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).font(.headline).foregroundStyle(Workshop.ink)
                                Text(t.summary).font(.subheadline).foregroundStyle(Workshop.ink2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "questionmark.circle").foregroundStyle(Workshop.ink3).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(t.title): \(t.summary)")
                    .accessibilityHint("Opens help")
                }
            } footer: { Text(HelpContent.safeLine) }
        }
        .navigationTitle("What can PixelPare do?")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $selected) { d in HelpSheet(topic: d).environment(model) }
    }
}

extension Destination: Identifiable { public var id: Self { self } }
