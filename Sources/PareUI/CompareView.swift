import PareCore
import SwiftUI

/// A/B on one frame: the original against a few-second preview encode. The encode only starts when asked.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: MediaID
    @State private var comparison: Comparison?
    @State private var failure: String?
    @State private var loading = false
    @State private var split = 0.5

    var body: some View {
        let item = model.items[id]
        let preset = model.preset
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Silk("A / B · one frame")
                        Text(model.title(for: id)).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
                    }
                    Spacer()
                    Button("Close") { dismiss() }.buttonStyle(.chunkyPlain).keyboardShortcut(.cancelAction)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Workshop.bezel)
                    if let c = comparison {
                        slider(c, preset: preset)
                    } else if loading {
                        VStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Encoding a few seconds with \(preset.title)…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                        }
                    } else {
                        VStack(spacing: 10) {
                            Text(failure ?? "Render a few seconds from the middle of the video to compare one frame.")
                                .font(.callout).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                            Button(failure == nil ? "Render preview" : "Try again") { Task { await load() } }
                                .buttonStyle(.chunky)
                        }
                        .padding()
                    }
                }
                .frame(height: 280)

                HStack {
                    Label("A · Original · \(Format.bytes(item?.byteSize ?? 0))", systemImage: "a.circle")
                    Spacer()
                    if let c = comparison {
                        Label("B · \(preset.title) · ≈\(Format.range(c.estimate.low...c.estimate.high)) (sample-based)", systemImage: "b.circle")
                    }
                }
                .font(.footnote).foregroundStyle(Workshop.ink2)
                Text("Drag the divider. The preview is a short encode from the middle of the video, so the final size can differ. Change the preset on the press and render again to compare another.")
                    .font(.footnote).foregroundStyle(Workshop.ink2)
                whatHappens(item, preset: preset)
            }
            .padding(20)
        }
        .background(BenchBackground())
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
        #endif
    }

    private func load() async {
        loading = true; failure = nil; comparison = nil
        defer { loading = false }
        do { comparison = try await model.loadComparison(id: id, preset: model.preset) }
        catch {
            failure = model.items[id]?.isLocal == false
                ? "The original is in iCloud. Download it first to compare." : error.localizedDescription
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
            Text("1. A second, smaller copy is added and verified. The original stays.").font(.footnote)
            Text("2. You then decide whether to remove the original. Removal applies on all your devices.").font(.footnote)
            Group {
                Label("Date, time, location, favorite and your albums are carried over", systemImage: "checkmark.circle")
                Label("Audio is copied without re-encoding", systemImage: "checkmark.circle")
                if let s = settings, let item {
                    let scaled = max(s.width, s.height) < max(item.pixelWidth, item.pixelHeight)
                    Label(scaled ? "\(Format.resolution(item)) → \(s.width)×\(s.height) at \(Int(s.frameRate.rounded())) fps"
                                 : "Keeps \(Format.resolution(item)) at \(Int(s.frameRate.rounded())) fps", systemImage: "checkmark.circle")
                }
                Label("Not in shared albums or Memories", systemImage: "exclamationmark.triangle").foregroundStyle(Workshop.amberDark)
                Label("It's a new item. Links to the old one break", systemImage: "exclamationmark.triangle").foregroundStyle(Workshop.amberDark)
            }
            .font(.footnote).foregroundStyle(Workshop.ink2)
            Text("Checks: plays fully · same length · audio · orientation").font(.caption).foregroundStyle(Workshop.ink3)
        }
        .foregroundStyle(Workshop.ink)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .workshopModule(radius: 18, screws: false)
    }
}
