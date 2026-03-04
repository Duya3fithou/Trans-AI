import Foundation

struct ModelCheckResult {
    let whisperReady: Bool
    let translationReady: Bool
    let missingFiles: [String]

    var allReady: Bool {
        whisperReady && translationReady
    }
}

@MainActor
final class ModelManager {
    private let bundleID = "com.example.TranscribeTranslateApp"

    var modelRootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    func ensureModelRootExists() throws {
        try FileManager.default.createDirectory(
            at: modelRootDirectory,
            withIntermediateDirectories: true
        )
    }

    func displayPath() -> String {
        modelRootDirectory.path
    }

    func checkModels() -> ModelCheckResult {
        let whisperDirectory = modelRootDirectory.appendingPathComponent("faster-whisper-small", isDirectory: true)
        let translationDirectory = modelRootDirectory.appendingPathComponent("nllb-200-distilled-600M", isDirectory: true)

        let whisperRequired = [
            "config.json",
            "model.bin"
        ]
        let translationRequired = [
            "config.json"
        ]

        var missing: [String] = []

        for filename in whisperRequired where !fileExists(in: whisperDirectory, name: filename) {
            missing.append("faster-whisper-small/\(filename)")
        }

        for filename in translationRequired where !fileExists(in: translationDirectory, name: filename) {
            missing.append("nllb-200-distilled-600M/\(filename)")
        }

        let hasTranslationWeights = fileExists(in: translationDirectory, name: "pytorch_model.bin")
            || fileExists(in: translationDirectory, name: "model.safetensors")
            || containsShardedWeights(in: translationDirectory)
        let hasTranslationTokenizer = fileExists(in: translationDirectory, name: "tokenizer.json")
            || fileExists(in: translationDirectory, name: "sentencepiece.bpe.model")
            || fileExists(in: translationDirectory, name: "spiece.model")

        if !hasTranslationWeights {
            missing.append("nllb-200-distilled-600M/(pytorch_model.bin or model.safetensors)")
        }

        if !hasTranslationTokenizer {
            missing.append("nllb-200-distilled-600M/(tokenizer.json or sentencepiece.bpe.model)")
        }

        let whisperReady = missing.allSatisfy { !$0.hasPrefix("faster-whisper-small/") }
        let translationReady = missing.allSatisfy { !$0.hasPrefix("nllb-200-distilled-600M/") }

        return ModelCheckResult(
            whisperReady: whisperReady,
            translationReady: translationReady,
            missingFiles: missing
        )
    }

    private func fileExists(in directory: URL, name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    private func containsShardedWeights(in directory: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return entries.contains(where: { entry in
            (entry.hasPrefix("pytorch_model-") && entry.hasSuffix(".bin"))
                || (entry.hasPrefix("model-") && entry.hasSuffix(".safetensors"))
        })
    }
}
