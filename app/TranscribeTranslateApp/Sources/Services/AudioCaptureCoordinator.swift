import Foundation

@MainActor
final class AudioCaptureCoordinator {
    private(set) var isCapturing = false
    private var timer: DispatchSourceTimer?

    var onAudioChunk: ((Data) -> Void)?

    // TODO: Replace this mock with ScreenCaptureKit capture for system audio + microphone.
    func startMockCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        let queue = DispatchQueue(label: "com.example.TranscribeTranslateApp.audio")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(700))
        timer.setEventHandler { [weak self] in
            // 0.5s of 16kHz mono PCM16 (simulated silence)
            let data = Data(repeating: 0, count: 16_000)
            Task { @MainActor in
                self?.onAudioChunk?(data)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stopCapture() {
        isCapturing = false
        timer?.cancel()
        timer = nil
    }
}
