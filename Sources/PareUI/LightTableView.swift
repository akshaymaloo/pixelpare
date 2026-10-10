import PareCore
import SwiftUI

/// Lookalike groups laid out on a lit table. The keeper is lit, extras are marked, favorites are protected.
struct LightTableView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.calm) private var calm
    @State private var currentID: UUID?
    @State private var focusedMember: MediaID?
    @State private var peek: MediaID?

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        let groups = model.sortedGroups
        Group {
            if groups.isEmpty {
                EmptyShelf(symbol: "square.on.square", title: "No lookalikes",
                           message: "No groups of near-identical photos were found.")
            } else {
                let g = groups.first { $0.id == currentID } ?? groups[0]
                let layout = compact ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                layout {
                    TrayStrip(groups: groups, current: g.id, axis: compact ? .horizontal : .vertical) { select($0) }
                    VStack(spacing: 12) {
                        LightSurface(group: g, index: (groups.firstIndex { $0.id == g.id } ?? 0) + 1, count: groups.count,
                                     focused: $focusedMember, peek: $peek, step: { moveGroup(groups, from: g.id, by: $0) })
                        GroupActionBar(group: g, advance: { advance(groups, from: g.id) })
                    }
                }
                .padding(compact ? 10 : 16)
                .onAppear { if currentID == nil { currentID = groups[0].id } }
            }
        }
        .background(BenchBackground())
        .overlay { if let id = peek { PeekOverlay(id: id) { peek = nil }.transition(.opacity) } }
        .animation(calm ? nil : .easeOut(duration: 0.15), value: peek)
        .navigationTitle("Lookalike tray")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                @Bindable var m = model
                if compact {
                    Menu {
                        Picker("Sort", selection: $m.groupSort) {
                            ForEach(GroupSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                        .accessibilityLabel("Sort groups")
                    CalmToggle(iconOnly: true)
                    Button { model.showPlan = true } label: { Label("Review receipt", systemImage: "receipt").labelStyle(.iconOnly) }
                        .accessibilityLabel("Review receipt")
                        .disabled(model.plan.isEmpty)
                } else {
                    Picker("Sort", selection: $m.groupSort) {
                        ForEach(GroupSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    CalmToggle()
                    Button { model.showPlan = true } label: { Label("Review receipt", systemImage: "receipt") }
                        .disabled(model.plan.isEmpty)
                }
            }
        }
    }

    private func select(_ id: UUID) {
        currentID = id; focusedMember = nil
    }

    private func moveGroup(_ groups: [SimilarGroup], from id: UUID, by delta: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(0, i + delta), groups.count - 1)
        select(groups[j].id)
    }

    private func advance(_ groups: [SimilarGroup], from id: UUID) {
        moveGroup(groups, from: id, by: 1)
    }
}

// MARK: Tray strip

private struct TrayStrip: View {
    @Environment(AppModel.self) private var model
    let groups: [SimilarGroup]
    let current: UUID
    let axis: Axis
    let select: (UUID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(axis == .vertical ? .vertical : .horizontal, showsIndicators: false) {
                let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    if axis == .vertical { Silk("Tray").frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(groups) { g in tile(g).id(g.id) }
                }
                .padding(axis == .vertical ? 10 : 6)
            }
            .frame(width: axis == .vertical ? 112 : nil, height: axis == .vertical ? nil : 76)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Workshop.plastic.opacity(0.6)))
            .onChange(of: current) { _, new in withAnimation { proxy.scrollTo(new, anchor: .center) } }
        }
    }

    private func tile(_ g: SimilarGroup) -> some View {
        let selected = g.id == current
        return Button { select(g.id) } label: {
            PolaroidFrame(corner: 5, border: 3, bottom: 3) {
                ThumbnailView(id: model.keeper(for: g), maxPixel: 200).aspectRatio(4 / 3, contentMode: .fit)
            }
            .frame(width: axis == .vertical ? 88 : 72)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.teal, lineWidth: selected ? 2.5 : 0).padding(-3))
            .overlay(alignment: .topTrailing) { badge(g).offset(x: 6, y: -6) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.groupTitle(g)), \(status(g))")
    }

    @ViewBuilder private func badge(_ g: SimilarGroup) -> some View {
        switch g.approval {
        case .approved:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Brand.teal).font(.title3)
        case .skipped:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(.white, Workshop.ink3).font(.title3)
        case .suggested:
            let n = model.keepSet(for: g).count
            Text("\(g.members.count - n)").font(.caption2.bold()).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Workshop.amber))
                .opacity(g.members.count - n > 0 ? 1 : 0)
        }
    }

    private func status(_ g: SimilarGroup) -> String {
        switch g.approval { case .approved: "approved"; case .skipped: "kept as they are"; case .suggested: "not decided" }
    }
}

// MARK: Lit surface

private struct LightSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let group: SimilarGroup
    let index: Int
    let count: Int
    @Binding var focused: MediaID?
    @Binding var peek: MediaID?
    let step: (Int) -> Void

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        let keep = model.keepSet(for: group)
        let columns = [GridItem(.adaptive(minimum: compact ? 150 : 250), spacing: 14, alignment: .top)]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Silk("Backlit · opaque white · true colour", color: Workshop.tealDark)
                    Text(model.groupTitle(group))
                        .font(.system(compact ? .headline : .title3, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
                }
                Spacer()
                Silk("Group \(index) of \(count)", color: Workshop.ink2)
                #if os(macOS)
                HStack(spacing: 4) {
                    Button { step(-1) } label: { Image(systemName: "chevron.up") }.keyboardShortcut(.upArrow, modifiers: .command)
                    Button { step(1) } label: { Image(systemName: "chevron.down") }.keyboardShortcut(.downArrow, modifiers: .command)
                }
                .buttonStyle(.borderless).help("Previous / next group (⌘↑ ⌘↓)")
                #endif
            }
            if case .approved = group.approval {
                Banner(symbol: "checkmark.seal", tint: Workshop.tealDark,
                       text: "Approved. \(Format.count(group.approvedRemovals.count, "photo")) will be removed only when you confirm the receipt.")
            } else if group.approval == .skipped {
                Banner(symbol: "hand.raised", tint: Workshop.ink2, text: "Kept as they are. Nothing in this group will be removed.")
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(group.members, id: \.self) { id in
                        LightCard(group: group, id: id, keeping: keep.contains(id), isFocused: focused == id, peek: $peek)
                            .onTapGesture { focused = id }
                    }
                }
                .padding(.vertical, 6)
            }
            Text(group.favorites.isEmpty ? "Marking is a selection, not a deletion. Undo mark puts a photo back."
                                         : "Favorites carry a heart shield and can never be marked.")
                .font(.footnote).foregroundStyle(Workshop.ink2)
        }
        .padding(compact ? 12 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LampGrid())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Workshop.bezel)
            .shadow(color: Workshop.shadow.opacity(0.35), radius: 14, y: 10))
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            let d = GroupSwipe.resolve(translation: v.translation).delta
            if d != 0 { step(d) }
        })
        .accessibilityAction(named: "Next group") { step(1) }
        .accessibilityAction(named: "Previous group") { step(-1) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveFocus(-1); return .handled }
        .onKeyPress(.rightArrow) { moveFocus(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.space) {
            if let f = focused ?? group.members.first(where: { !group.favorites.contains($0) && !keep.contains($0) }) {
                toggle(f)
            }
            return .handled
        }
    }

    private func moveFocus(_ delta: Int) {
        let members = group.members
        let i = focused.flatMap { members.firstIndex(of: $0) } ?? (delta > 0 ? -1 : members.count)
        focused = members[min(max(0, i + delta), members.count - 1)]
    }

    private func toggle(_ id: MediaID) {
        guard !group.favorites.contains(id) else { return }
        model.toggleKeep(group: group.id, member: id)
    }
}

private struct LampGrid: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Workshop.lamp, Color(hex: 0xF5FBFA)], startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var p = Path()
                var x: CGFloat = 0
                while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += 24 }
                var y: CGFloat = 0
                while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += 24 }
                ctx.stroke(p, with: .color(Brand.teal.opacity(0.07)), lineWidth: 1)
            }
        }
    }
}

private struct LightCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.calm) private var calm
    @Environment(\.horizontalSizeClass) private var sizeClass
    let group: SimilarGroup
    let id: MediaID
    let keeping: Bool
    let isFocused: Bool
    @Binding var peek: MediaID?
    @State private var drag: CGFloat = 0
    @State private var shakes: CGFloat = 0
    @State private var protectedHint = false

    private var compact: Bool { sizeClass == .compact }
    private var isFavorite: Bool { group.favorites.contains(id) }
    private var isKeeper: Bool { id == model.keeper(for: group) }
    private var marked: Bool { !keeping && !isFavorite }

    var body: some View {
        VStack(spacing: 8) {
            PolaroidFrame(corner: 8, border: 8, bottom: 8) {
                ThumbnailView(id: id, maxPixel: 700).aspectRatio(4 / 3, contentMode: .fit)
                    .saturation(marked ? 0.8 : 1)
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Brand.teal, lineWidth: keeping && !isFavorite ? 3 : 0))
            .shadow(color: keeping && !isFavorite ? Brand.teal.opacity(0.35) : .clear, radius: 12)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Workshop.blueDark.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [5, 3])).opacity(isFocused ? 1 : 0))
            .overlay(alignment: .topLeading) { leadingTab.offset(x: 6, y: -8) }
            .overlay(alignment: .topTrailing) {
                if marked { tab("MARKED", symbol: "bookmark.fill", fill: Workshop.amber, ink: Workshop.ink).offset(x: -6, y: -8) }
            }
            .opacity(marked ? 0.82 : 1)
            .settle(value: marked)
            .overlay(alignment: .bottom) {
                if protectedHint {
                    Label("Protected", systemImage: "lock.fill").font(.caption.weight(.bold)).foregroundStyle(Workshop.heart)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Workshop.paper).shadow(radius: 2)).padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
            .modifier(ShakeEffect(travel: shakes))
            .offset(y: drag)
            .simultaneousGesture(swipe)
            .onTapGesture(count: 2) { if !isKeeper && !isFavorite { makeKeeper() } }
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 12, perform: { peek = id },
                                onPressingChanged: { if !$0 { peek = nil } })
            .sensoryFeedback(trigger: shakes) { _, _ in calm ? nil : .warning }
            .sensoryFeedback(trigger: marked) { _, _ in calm ? nil : .impact(weight: .light) }

            VStack(alignment: .leading, spacing: 4) {
                let dateText = Text(model.title(for: id)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Workshop.ink)
                let statusText = Text(caption).font(.caption).foregroundStyle(Workshop.ink2)
                if compact {
                    VStack(alignment: .leading, spacing: 2) { dateText; statusText }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .firstTextBaseline) { dateText; Spacer(); statusText.multilineTextAlignment(.trailing) }
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if isFavorite {
                        Label("Protected · no mark slot", systemImage: "lock.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Workshop.heart)
                    } else if isKeeper {
                        Label("Keeper · always stays", systemImage: "star.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Workshop.tealDark)
                    } else {
                        Button {
                            Feedback.tick(calm: calm)
                            model.toggleKeep(group: group.id, member: id)
                        } label: { Text(keeping ? "Mark" : "Undo").lineLimit(1).frame(maxWidth: .infinity) }
                            .buttonStyle(.chunkyPlain).controlSize(.small)
                            .accessibilityHint(keeping ? "Marks this photo for removal if you approve the group"
                                                       : "Puts this photo back; it will be kept")
                        Button { Feedback.tick(calm: calm); model.setKeeper(group: group.id, member: id) } label: {
                            Image(systemName: "star").frame(minWidth: 18)
                        }
                        .buttonStyle(.chunkyPlain).controlSize(.small)
                        .accessibilityLabel("Make keeper")
                        .help("Make keeper. The current keeper stays kept until you mark it")
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if !isFavorite && !isKeeper {
                Button(keeping ? "Mark" : "Undo mark") { model.toggleKeep(group: group.id, member: id) }
                Button("Make keeper") { makeKeeper() }
            }
        }
    }

    private func makeKeeper() {
        Feedback.tick(calm: calm)
        model.setKeeper(group: group.id, member: id)
    }

    /// Vertical swipe: up marks, down undoes. Off in Calm mode; the buttons remain.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                guard !calm, SwipeDecision.isVertical(v.translation) else { return }
                drag = SwipeDecision.rubberBand(v.translation.height, limit: isFavorite || isKeeper ? 10 : 90)
            }
            .onEnded { v in
                defer { withAnimation(calm ? nil : .spring(duration: 0.3, bounce: 0.3)) { drag = 0 } }
                guard !calm else { return }
                switch SwipeDecision.resolve(translation: v.translation, isKeeper: isKeeper, isFavorite: isFavorite, isMarked: marked) {
                case .mark where keeping, .unmark where !keeping:
                    model.toggleKeep(group: group.id, member: id)
                case .protected:
                    withAnimation(.linear(duration: 0.3)) { shakes += 1; protectedHint = true }
                    Task { try? await Task.sleep(for: .seconds(1.1)); withAnimation { protectedHint = false } }
                case .resist:
                    withAnimation(.linear(duration: 0.2)) { shakes += 1 }
                default: break
                }
            }
    }

    private var caption: String {
        if isFavorite { return "♥ Favorite" }
        if isKeeper { return "Keeper" }
        if marked { return model.group(group.id)?.reasons[id]?.first ?? "Nearly the same as the keeper" }
        return "Kept"
    }

    @ViewBuilder private var leadingTab: some View {
        if isFavorite {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").font(.caption2)
                Text("PROTECTED").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(0.8)
            }
            .foregroundStyle(Workshop.heart)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Workshop.paper).shadow(color: Workshop.shadow.opacity(0.25), radius: 2, y: 1))
        } else if isKeeper {
            tab("KEEPER", symbol: "star.fill", fill: Brand.teal, ink: .white)
        } else if keeping {
            tab("KEPT", symbol: "checkmark", fill: Brand.teal.opacity(0.85), ink: .white)
        }
    }

    private func tab(_ text: String, symbol: String, fill: Color, ink: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption2)
            Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(0.8)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(fill).shadow(color: Workshop.shadow.opacity(0.25), radius: 2, y: 1))
    }
}

// MARK: Actions

private struct GroupActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let group: SimilarGroup
    let advance: () -> Void

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        let keep = model.keepSet(for: group)
        let marked = group.members.filter { !keep.contains($0) && !group.favorites.contains($0) }
        let approved: Bool = { if case .approved = group.approval { true } else { false } }()
        let summary = VStack(alignment: .leading, spacing: 2) {
            Silk("This group")
            Text(marked.isEmpty ? "Nothing marked" : "\(marked.count) marked · \(Format.bytes(model.savings(of: group)))")
                .font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
        }
        let buttons = HStack(spacing: 8) {
            Button { advance() } label: { Text("Skip").lineLimit(1) }
                .buttonStyle(.chunkyPlain).keyboardShortcut("s", modifiers: [])
                .help("Decide later (S)")
            Button { model.skipGroup(group.id); advance() } label: { Text(compact ? "Keep all" : "Keep group").lineLimit(1) }
                .buttonStyle(.chunkyPlain).keyboardShortcut("k", modifiers: [])
                .help("Keep every photo in this group (K)")
            if approved {
                Button { model.unapproveGroup(group.id) } label: { Text("Undo approval").lineLimit(1) }
                    .buttonStyle(.chunkyPlain)
            } else {
                Button { model.approveGroup(group.id); advance() } label: { Text(compact ? "Approve" : "Approve group").lineLimit(1) }
                    .buttonStyle(.chunky).keyboardShortcut(.return, modifiers: [])
                    .disabled(marked.isEmpty)
                    .help("Approve removing the marked photos (Return)")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) { summary; buttons }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    summary
                    HStack(spacing: 6) {
                        ForEach(marked.prefix(4), id: \.self) { id in
                            PolaroidFrame(corner: 4, border: 2, bottom: 2) { ThumbnailView(id: id, maxPixel: 120).frame(width: 34, height: 26) }
                        }
                    }
                    Text("The keeper stays in every group. Approving only adds to the plan; nothing is removed until you confirm the receipt.")
                        .font(.footnote).foregroundStyle(Workshop.ink2).lineLimit(3)
                    Spacer(minLength: 4)
                    buttons
                }
            }
        }
        .padding(.horizontal, compact ? 12 : 20).padding(.vertical, 8)
        .workshopModule(radius: 20, screws: false)
    }
}

#if DEBUG
#Preview("Light table") {
    PreviewHost { NavigationStack { LightTableView() } }
}
#endif
