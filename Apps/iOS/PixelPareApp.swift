import PareUI
import SwiftUI

@main
struct PixelPareApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            PixelPareRootView(model: model)
        }
    }
}
