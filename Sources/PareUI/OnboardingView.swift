import PareCore
import PareLibrary
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var pickFolder = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ReelIcon(spinning: false, size: 80)
            Text("Free up space, safely").font(.system(.largeTitle, design: .rounded, weight: .heavy)).foregroundStyle(Workshop.ink)
            Text(model.access == .denied
                 ? "PixelPare doesn't have access to your photos. Turn on Photos access in Settings to continue."
                 : "PixelPare finds similar photos, old screenshots and large videos. It works from thumbnails first, and nothing is removed until you approve it.")
                .font(.body).foregroundStyle(Workshop.ink2).multilineTextAlignment(.center).frame(maxWidth: 440)
            if model.access == .denied {
                Button("Open Settings") { openSettings() }.buttonStyle(.chunky)
                Button("Check again") { Task { await model.recheckAccess() } }.buttonStyle(.borderless)
            } else {
                Button("Allow access to Photos") { Task { await model.requestAccess() } }.buttonStyle(.chunky)
            }
            #if os(macOS)
            Button("Use a folder instead…") { pickFolder = true }.buttonStyle(.borderless)
            #endif
            Spacer()
        }
        .padding(32).frame(maxWidth: .infinity).background(BenchBackground())
        #if os(macOS)
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { Task { await model.useSource(.folder(url)) } }
        }
        #endif
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { openURL(url) }
        #endif
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var pickFolder = false

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Source", value: model.sourceName)
                LabeledContent("Photos access", value: accessText)
                if model.source == .photos {
                    if model.access == .limited {
                        Text("Only the photos you selected are scanned. Change the selection in the system Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Use the Photos library") { Task { await model.useSource(.photos) } }
                }
                Button("Choose a folder (developer / testing)…") { pickFolder = true }
                Button("Scan again") { model.rescan() }
            }
            Section("Videos") {
                @Bindable var m = model
                Toggle("Download videos over cellular", isOn: $m.allowCellular)
                Text("Turn off to download iCloud videos only on Wi‑Fi. Pressing waits for Wi‑Fi instead of using mobile data.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Safety") {
                Text("Matching is conservative: only very similar shots are grouped. Favorites are never suggested for removal, every group keeps at least one photo, and original videos are only removed after you approve it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Link("About Recently Deleted", destination: URL(string: "https://support.apple.com/108922")!)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { Task { await model.useSource(.folder(url)) } }
        }
    }

    private var accessText: String {
        switch model.access {
        case .full: "Full"
        case .limited: "Limited"
        case .denied: "Denied"
        case .notDetermined: "Not asked yet"
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.history.isEmpty {
                EmptyShelf(symbol: "clock.arrow.circlepath", title: "No history yet",
                           message: "Videos you press will be listed here.")
            } else {
                List(model.history, id: \.original) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title(for: e.original)).font(.headline)
                        Text(describe(e.state)).font(.subheadline).foregroundStyle(.secondary)
                        if let err = e.error { Text(err).font(.caption).foregroundStyle(.orange) }
                        Text(e.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("History")
        .task { await model.refreshHistory() }
    }

    private func describe(_ s: OperationJournal.State) -> String {
        switch s {
        case .planned, .preflight: "Planned"
        case .downloading: "Getting the original…"
        case .downloaded: "Original prepared"
        case .encoding: "Compressing…"
        case .encoded: "Compressed"
        case .verified: "Verified"
        case .importing: "Adding the smaller copy…"
        case .imported: "Smaller copy added"
        case .awaitingRemovalApproval: "Smaller copy ready · original kept"
        case .removing: "Removing the original…"
        case .removed: "Original removed"
        case .skipped: "Skipped"
        case .failed: "Not completed"
        }
    }
}
