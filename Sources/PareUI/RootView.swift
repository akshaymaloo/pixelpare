import PareCore
import PareLibrary
import SwiftUI

/// Root of both apps: onboarding, the workbench stack, the press in progress, or the recap.
public struct PixelPareRootView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        @Bindable var m = model
        Group {
            if !model.accessChecked {
                ProgressView()
            } else if model.access == .denied || model.access == .notDetermined {
                OnboardingView()
            } else {
                switch model.stage {
                case .working(let p): WorkingView(progress: p)
                case .done(let s): RecapView(summary: s)
                case .browsing:
                    NavigationStack(path: $m.path) {
                        WorkbenchView()
                            .navigationDestination(for: Destination.self) { d in
                                switch d {
                                case .home: WorkbenchView()
                                case .similar: LightTableView()
                                case .videos: VideoPressView()
                                case .screenshots: ScreenshotsView()
                                case .blurry: BlurryView()
                                case .recordings: RecordingsView()
                                case .biggest: BiggestView()
                                case .bursts: BurstsView()
                                case .livePhotos: LivePhotosView()
                                case .history: HistoryView()
                                case .settings: SettingsView()
                                }
                            }
                    }
                }
            }
        }
        .environment(model)
        .environment(\.calm, model.calmMode || reduceMotion)
        .preferredColorScheme(.light)
        .tint(Brand.blue)
        .sheet(isPresented: $m.showPlan) {
            let working: Bool = { if case .working = model.stage { true } else { false } }()
            PlanReceiptView().environment(model).preferredColorScheme(.light)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(ReceiptDismissal.isLocked(isRemoving: model.isRemoving, isWorking: working))
        }
        .alert("Something went wrong", isPresented: Binding(get: { m.errorMessage != nil && !m.showPlan }, set: { if !$0 { m.errorMessage = nil } })) {
            Button("OK") { m.errorMessage = nil }
        } message: { Text(m.errorMessage ?? "") }
        .task { await model.start() }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 640)
        #endif
    }
}

#if DEBUG
@MainActor func previewModel() -> AppModel {
    AppModel(library: SampleLibrary(),
             supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("pixelpare-preview-\(UUID().uuidString)"))
}

/// Hosts a view with a sample-library model that has scanned.
struct PreviewHost<Content: View>: View {
    @State private var model = previewModel()
    @ViewBuilder var content: Content
    var body: some View {
        content.environment(model).environment(\.calm, false).preferredColorScheme(.light)
            .task { await model.start() }
    }
}

#Preview("Root (sample library)") {
    PixelPareRootView(model: previewModel())
}

#Preview("Onboarding") {
    OnboardingView().environment(previewModel())
}
#endif
