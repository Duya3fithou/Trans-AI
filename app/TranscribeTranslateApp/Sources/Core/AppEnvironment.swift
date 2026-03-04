import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let sessionViewModel: SessionViewModel

    init() {
        let modelManager = ModelManager()
        let workerBridge = WorkerBridge()
        let audioCapture = AudioCaptureCoordinator()
        let exporter = TranscriptExporter()

        self.sessionViewModel = SessionViewModel(
            workerBridge: workerBridge,
            modelManager: modelManager,
            audioCapture: audioCapture,
            exporter: exporter
        )
    }
}
