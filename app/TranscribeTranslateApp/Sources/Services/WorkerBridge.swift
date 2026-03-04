import Foundation

@MainActor
final class WorkerBridge: ObservableObject {
    @Published private(set) var isRunning = false

    var onEvent: ((WorkerEvent) -> Void)?

    private let writeQueue = DispatchQueue(
        label: "com.example.TranscribeTranslateApp.worker.write",
        qos: .userInitiated
    )
    private let maxPendingAudioWrites = 8

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var pendingAudioWriteCount = 0
    private var isStopping = false

    func start() throws {
        guard process == nil else { return }

        let scriptPath = try resolveWorkerScriptPath()
        let launch = try resolvePythonLaunch()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executablePath)
        process.arguments = launch.arguments + [scriptPath]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.appendStdoutData(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                fputs("[worker stderr] \(text)", stderr)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.process = nil
                self?.stdinHandle = nil
                self?.pendingAudioWriteCount = 0
                self?.isStopping = false
            }
        }

        try process.run()

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.isRunning = true
        self.isStopping = false
    }

    func stop() {
        guard let process else { return }
        isStopping = true
        try? sendCommand(
            WorkerCommand(
                type: .stop,
                targetLanguage: nil,
                modelRoot: nil,
                audioBase64: nil,
                sampleRate: nil,
                channels: nil
            )
        )

        try? stdinHandle?.close()
        self.stdinHandle = nil
        self.pendingAudioWriteCount = 0

        // Give worker a short window to exit gracefully after `stop`.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }
    }

    func requestModelDownload(modelRoot: String) throws {
        try sendCommand(
            WorkerCommand(
                type: .downloadModels,
                targetLanguage: nil,
                modelRoot: modelRoot,
                audioBase64: nil,
                sampleRate: nil,
                channels: nil
            )
        )
    }

    func requestWarmup(targetLanguage: String) throws {
        try sendCommand(
            WorkerCommand(
                type: .warmup,
                targetLanguage: targetLanguage,
                modelRoot: nil,
                audioBase64: nil,
                sampleRate: nil,
                channels: nil
            )
        )
    }

    func sendAudioChunk(_ data: Data, sampleRate: Int = 16_000, channels: Int = 1) throws {
        guard let stdinHandle else {
            throw NSError(domain: "WorkerBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Worker not started"])
        }

        if pendingAudioWriteCount >= maxPendingAudioWrites {
            return
        }

        let payload = try encodeCommand(
            WorkerCommand(
                type: .processAudio,
                targetLanguage: nil,
                modelRoot: nil,
                audioBase64: data.base64EncodedString(),
                sampleRate: sampleRate,
                channels: channels
            )
        )
        pendingAudioWriteCount += 1

        writeQueue.async { [weak self] in
            defer {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingAudioWriteCount = max(self.pendingAudioWriteCount - 1, 0)
                }
            }

            do {
                try stdinHandle.write(contentsOf: payload)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isStopping else { return }
                    self.onEvent?(
                        WorkerEvent(
                            type: .error,
                            message: "Failed to send audio to worker: \(error.localizedDescription)",
                            progress: nil,
                            partial: nil,
                            segment: nil
                        )
                    )
                }
            }
        }
    }

    private func sendCommand(_ command: WorkerCommand) throws {
        guard let stdinHandle else {
            throw NSError(domain: "WorkerBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Worker not started"])
        }
        let payload = try encodeCommand(command)
        try writeSync(payload, to: stdinHandle)
    }

    private func encodeCommand(_ command: WorkerCommand) throws -> Data {
        let encoded = try JSONEncoder().encode(command)
        var withNewline = encoded
        withNewline.append(0x0A)
        return withNewline
    }

    private func writeSync(_ payload: Data, to handle: FileHandle) throws {
        var capturedError: Error?
        writeQueue.sync {
            do {
                try handle.write(contentsOf: payload)
            } catch {
                capturedError = error
            }
        }

        if let capturedError {
            throw capturedError
        }
    }

    private func appendStdoutData(_ data: Data) {
        stdoutBuffer.append(data)

        while let newlineRange = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)

            guard !lineData.isEmpty,
                  let event = try? JSONDecoder().decode(WorkerEvent.self, from: lineData)
            else {
                continue
            }
            onEvent?(event)
        }
    }

    private func resolveWorkerScriptPath() throws -> String {
        if let explicit = ProcessInfo.processInfo.environment["TT_WORKER_SCRIPT_PATH"],
           FileManager.default.fileExists(atPath: explicit) {
            return explicit
        }

        let candidate = FileManager.default.currentDirectoryPath + "/worker/src/worker_main.py"
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }

        throw NSError(
            domain: "WorkerBridge",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Cannot find worker_main.py. Set TT_WORKER_SCRIPT_PATH."]
        )
    }

    private func resolvePythonLaunch() throws -> (executablePath: String, arguments: [String]) {
        let environment = ProcessInfo.processInfo.environment
        var configuredPathError: String?

        if let configured = environment["TT_PYTHON_PATH"], !configured.isEmpty {
            if configured.hasPrefix("/") {
                if FileManager.default.isExecutableFile(atPath: configured) {
                    return (configured, [])
                }

                configuredPathError = "Configured TT_PYTHON_PATH is not executable: \(configured)"
            } else {
                // Allow values like `python3` or `python3.11`.
                return ("/usr/bin/env", [configured])
            }
        }

        let preferredPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        for path in preferredPaths where FileManager.default.isExecutableFile(atPath: path) {
            return (path, [])
        }

        if FileManager.default.isExecutableFile(atPath: "/usr/bin/env") {
            return ("/usr/bin/env", ["python3"])
        }

        let details = configuredPathError ?? "Python 3 not found on this machine."
        throw NSError(
            domain: "WorkerBridge",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(details) Install python3 or set TT_PYTHON_PATH to an absolute path such as /opt/homebrew/bin/python3."
            ]
        )
    }
}
