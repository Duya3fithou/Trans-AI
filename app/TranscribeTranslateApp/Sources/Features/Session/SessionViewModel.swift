import Foundation

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var statusMessage = "Idle"
    @Published var downloadProgress: Double = 0
    @Published var targetLanguage = "vie_Latn"
    @Published var records: [TranscriptRecord] = []
    @Published var exportedFilePath: String?
    @Published var livePartialText = ""
    @Published var livePartialStartSeconds: Double?
    @Published var livePartialEndSeconds: Double?

    private let workerBridge: WorkerBridge
    private let modelManager: ModelManager
    private let audioCapture: AudioCaptureCoordinator
    private let exporter: TranscriptExporter
    private var pendingCaptureStart = false

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

        self.audioCapture.onCaptureError = { [weak self] message in
            self?.statusMessage = message
        }
    }

    func prepareModels() {
        do {
            try modelManager.ensureModelRootExists()
            downloadProgress = 0
            try ensureWorkerRunning()
            try workerBridge.requestModelDownload(modelRoot: modelManager.displayPath())
            statusMessage = "Preparing models at \(modelManager.displayPath())"
        } catch {
            statusMessage = "Prepare models failed: \(error.localizedDescription)"
        }
    }

    func checkModels() {
        do {
            try modelManager.ensureModelRootExists()
            let result = modelManager.checkModels()

            if result.allReady {
                downloadProgress = 1
                statusMessage = "Models ready: faster-whisper + NLLB"
                return
            }

            downloadProgress = 0
            if result.missingFiles.isEmpty {
                statusMessage = "Models are incomplete"
            } else {
                statusMessage = "Missing model files: \(result.missingFiles.joined(separator: ", "))"
            }
        } catch {
            statusMessage = "Check models failed: \(error.localizedDescription)"
        }
    }

    func startSession() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.livePartialText = ""
                self.livePartialStartSeconds = nil
                self.livePartialEndSeconds = nil
                try self.ensureWorkerRunning()
                self.pendingCaptureStart = true
                self.statusMessage = "Warming up AI pipeline..."
                try self.workerBridge.requestWarmup(targetLanguage: self.targetLanguage)
            } catch {
                self.pendingCaptureStart = false
                self.statusMessage = "Start session failed: \(error.localizedDescription)"
            }
        }
    }

    func stopSession() {
        pendingCaptureStart = false
        audioCapture.stopCapture()
        livePartialText = ""
        livePartialStartSeconds = nil
        livePartialEndSeconds = nil
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
        livePartialText = ""
        livePartialStartSeconds = nil
        livePartialEndSeconds = nil
    }

    var modelDirectory: String {
        modelManager.displayPath()
    }

    var downloadProgressLabel: String {
        let percent = Int((downloadProgress * 100).rounded())
        return "Download progress: \(percent)%"
    }

    var livePartialWindowLabel: String? {
        guard let start = livePartialStartSeconds, let end = livePartialEndSeconds else {
            return nil
        }
        return "[\(formatTime(start)) - \(formatTime(end))]"
    }

    private func ensureWorkerRunning() throws {
        if !workerBridge.isRunning {
            try workerBridge.start()
        }
    }

    private func handle(_ event: WorkerEvent) {
        switch event.type {
        case .status:
            let message = event.message ?? "Status updated"
            statusMessage = message
            if pendingCaptureStart && isPipelineReadyMessage(message) {
                pendingCaptureStart = false
                startCaptureAfterWarmup()
            }

        case .downloadProgress:
            if let progress = event.progress {
                downloadProgress = min(max(progress, 0), 1)
            }
            statusMessage = event.message ?? "Downloading models"

        case .partialSegment:
            guard let partial = event.partial else { return }
            livePartialText = partial.source_text
            livePartialStartSeconds = partial.start_seconds
            livePartialEndSeconds = partial.end_seconds

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
            livePartialText = ""
            livePartialStartSeconds = nil
            livePartialEndSeconds = nil

        case .error:
            pendingCaptureStart = false
            statusMessage = event.message ?? "Unknown worker error"
        }
    }

    private func isPipelineReadyMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("mock pipeline ready") || normalized.contains("real pipeline ready")
    }

    private func startCaptureAfterWarmup() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.audioCapture.startCapture()
                self.statusMessage = "Session started (live capture)"
            } catch {
                self.statusMessage = "Start session failed: \(error.localizedDescription)"
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
