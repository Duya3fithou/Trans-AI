import Foundation

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var statusMessage = "Idle"
    @Published var downloadProgress: Double = 0
    @Published var targetLanguage = "vie_Latn"
    @Published var records: [TranscriptRecord] = []
    @Published var exportedFilePath: String?

    private let workerBridge: WorkerBridge
    private let modelManager: ModelManager
    private let audioCapture: AudioCaptureCoordinator
    private let exporter: TranscriptExporter

    init(
        workerBridge: WorkerBridge,
        modelManager: ModelManager,
        audioCapture: AudioCaptureCoordinator,
        exporter: TranscriptExporter
    ) {
        self.workerBridge = workerBridge
        self.modelManager = modelManager
        self.audioCapture = audioCapture
        self.exporter = exporter

        self.audioCapture.onAudioChunk = { [weak self] chunk in
            guard let self else { return }
            do {
                try self.workerBridge.sendAudioChunk(chunk)
            } catch {
                self.statusMessage = "Send audio failed: \(error.localizedDescription)"
            }
        }

        self.workerBridge.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func prepareModels() {
        do {
            try modelManager.ensureModelRootExists()
            try ensureWorkerRunning()
            try workerBridge.requestModelDownload(modelRoot: modelManager.displayPath())
            statusMessage = "Preparing models at \(modelManager.displayPath())"
        } catch {
            statusMessage = "Prepare models failed: \(error.localizedDescription)"
        }
    }

    func startSession() {
        do {
            try ensureWorkerRunning()
            try workerBridge.requestWarmup(targetLanguage: targetLanguage)
            audioCapture.startMockCapture()
            statusMessage = "Session started (mock capture)"
        } catch {
            statusMessage = "Start session failed: \(error.localizedDescription)"
        }
    }

    func stopSession() {
        audioCapture.stopCapture()
        statusMessage = "Session stopped"
    }

    func exportTranscript() {
        do {
            let file = try exporter.export(records: records)
            exportedFilePath = file.path
            statusMessage = "Exported transcript: \(file.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func resetRecords() {
        records = []
        exportedFilePath = nil
    }

    var modelDirectory: String {
        modelManager.displayPath()
    }

    private func ensureWorkerRunning() throws {
        if !workerBridge.isRunning {
            try workerBridge.start()
        }
    }

    private func handle(_ event: WorkerEvent) {
        switch event.type {
        case .status:
            statusMessage = event.message ?? "Status updated"

        case .downloadProgress:
            downloadProgress = event.progress ?? downloadProgress
            statusMessage = event.message ?? "Downloading models"

        case .segment:
            guard let payload = event.segment else { return }
            let record = TranscriptRecord(
                segmentID: payload.segment_id,
                startSeconds: payload.start_seconds,
                endSeconds: payload.end_seconds,
                sourceText: payload.source_text,
                translatedText: payload.translated_text
            )
            records.append(record)

        case .error:
            statusMessage = event.message ?? "Unknown worker error"
        }
    }
}
