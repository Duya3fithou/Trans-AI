import SwiftUI

@main
struct TranscribeTranslateApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup("Transcribe Translate") {
            ContentView(viewModel: environment.sessionViewModel)
                .frame(minWidth: 960, minHeight: 620)
        }
    }
}
