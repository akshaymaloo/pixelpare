import PareCore
import SwiftUI

/// Check quality: the original against a short sample copy, on one frame. The sample only starts when asked.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: MediaID
    @State private var comparison: Comparison?
    @State private var failure: String?
    @State private var loading = false
    @State private var split = 0.5

    private let sampleSeconds = 3

    var body: some View {
        let item = model.items[id]
        let preset = model.preset
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    presetChips
                    imageArea(item, preset: preset, maxHeight: geo.size.height * 0.55)
                    sizeColumns(item, preset: preset)
                    Text("Drag to compare one frame. The sample is from the middle of the video.")
                        .font(.footnote).foregroundStyle(Workshop.ink2)
                    whatHappens(item, preset: preset)
                }
                .padding(20)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
        }
        .background(BenchBackground())
        .onChange(of: model.preset) { _, _ in comparison = nil; failure = nil }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
        #endif
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Silk("Check quality")
                Text(model.title(for: id)).font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Workshop.ink).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Done") { dismiss() }.buttonStyle(.chunkyPlain).keyboardShortcut(.cancelAction).lineLimit(1).fixedSize()
        }
    }

    private var presetChips: some View {
        HStack(spacing: 6) {
            ForEach(VideoPreset.allCases, id: \.self) { p in
                let on = p == model.preset
                let ok = model.isApplicable(id, preset: p)
                Button { model.preset = p } label: {
                    Text(p.title).font(.system(.footnote, design: .rounded, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(on ? .white : Workshop.ink)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Workshop.paper)))
                }
                .buttonStyle(.plain).disabled(!ok).opacity(ok ? 1 : 0.4)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func imageArea(_ item: MediaItem?, preset: VideoPreset, maxHeight: CGFloat) -> some View {
        var aspect: CGFloat = 4 / 3
        if let item, item.pixelWidth > 0, item.pixelHeight > 0 { aspect = CGFloat(item.pixelWidth) / CGFloat(item.pixelHeight) }
        if let c = comparison, c.original.height > 0 { aspect = CGFloat(c.original.width) / CGFloat(c.original.height) }
        let boxAspect = comparison == nil ? min(aspect, 4 / 3) : aspect
        return ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Workshop.bezel)
            if let c = comparison {
                slider(c, preset: preset)
            } else if loading {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Making a sample with \(preset.title)…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                VStack(spacing: 10) {
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                    }
                    Button(failure == nil ? "Make a \(sampleSeconds)‑second sample" : "Try again") { Task { await load() } }
                        .buttonStyle(.chunky).lineLimit(1).fixedSize()
                        .disabled(!model.isApplicable(id, preset: preset))
                }
                .padding()
            }
        }
        .overlay(alignment: .topLeading) { if comparison != nil { pill("Original") } }
        .overlay(alignment: .topTrailing) { if comparison != nil { pill(preset.title) } }
        .aspectRatio(boxAspect, contentMode: .fit)
        .frame(maxHeight: maxHeight)
        .frame(maxWidth: .infinity)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(.black.opacity(0.6)))
            .padding(8).allowsHitTesting(false)
    }

    private func sizeColumns(_ item: MediaItem?, preset: VideoPreset) -> some View {
        let estimate: String? = comparison.map { "≈ \(Format.range($0.estimate.low...$0.estimate.high))" }
            ?? model.sizeEstimate(for: id, preset: preset).map { "≈ \(Format.range($0.low...$0.high))" }
        return HStack(alignment: .top, spacing: 12) {
            column("Original", Format.bytes(item?.byteSize ?? 0))
            column("\(preset.title) copy", estimate ?? "–")
        }
    }

    private func column(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Workshop.ink2).lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.system(.headline, design: .monospaced, weight: .bold)).foregroundStyle(Workshop.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        loading = true; failure = nil; comparison = nil
        defer { loading = false }
        do { comparison = try await model.loadComparison(id: id, preset: model.preset) }
        catch {
            failure = model.items[id]?.isLocal == false
                ? "The original is in iCloud. Download it first to check quality." : error.localizedDescription
        }
    }

    private func slider(_ c: Comparison, preset: VideoPreset) -> some View {
        GeometryReader { geo in
            ZStack {
                Image(decorative: c.original, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                Image(decorative: c.preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(alignment: .trailing) { Rectangle().frame(width: geo.size.width * (1 - split)) }
                Rectangle().fill(.white).frame(width: 2).shadow(radius: 2)
                    .position(x: geo.size.width * split, y: geo.size.height / 2)
                Circle().fill(.white).frame(width: 34, height: 34).shadow(radius: 3)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
                    .position(x: geo.size.width * split, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { split = CompareSplit.fraction(x: $0.location.x, width: geo.size.width) })
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Original and \(preset.title) comparison slider")
        .accessibilityValue("\(Int(split * 100)) percent original")
        .accessibilityAdjustableAction { d in split = min(max(split + (d == .increment ? 0.1 : -0.1), 0), 1) }
    }

    @ViewBuilder private func whatHappens(_ item: MediaItem?, preset: VideoPreset) -> some View {
        let settings = item.flatMap { PresetPolicy.settings(for: $0, preset: preset) }
        VStack(alignment: .leading, spacing: 6) {
            Silk("What happens")
            Text("A smaller copy is added and checked. The original stays until you choose to remove it, on all your devices.")
                .font(.footnote)
            Group {
                Label("Date, place, favorite and albums carry over", systemImage: "checkmark.circle")
                Label("Audio is copied as it is", systemImage: "checkmark.circle")
                if let s = settings, let item {
                    let scaled = max(s.width, s.height) < max(item.pixelWidth, item.pixelHeight)
                    Label(scaled ? "\(Format.resolution(item)) → \(s.width)×\(s.height) at \(Int(s.frameRate.rounded())) fps"
                                 : "Keeps \(Format.resolution(item)) at \(Int(s.frameRate.rounded())) fps", systemImage: "checkmark.circle")
                }
                Label("Not in shared albums or Memories", systemImage: "exclamationmark.triangle").foregroundStyle(Workshop.amberDark)
                Label("It's a new item, so old links break", systemImage: "exclamationmark.triangle").foregroundStyle(Workshop.amberDark)
            }
            .font(.footnote).foregroundStyle(Workshop.ink2)
            Text("Checks: plays fully · same length · audio · orientation").font(.caption).foregroundStyle(Workshop.ink3)
        }
        .foregroundStyle(Workshop.ink)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .workshopModule(radius: 18, screws: false)
    }
}
