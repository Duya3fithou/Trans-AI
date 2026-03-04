import AppKit
import SwiftUI

@main
struct TranscribeTranslateApp: App {
    @StateObject private var environment = AppEnvironment()

    init() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            app.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Transcribe Translate") {
            ContentView(viewModel: environment.sessionViewModel)
                .frame(minWidth: 960, minHeight: 620)
        }
    }
}
