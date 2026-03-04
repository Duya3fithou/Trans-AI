import Foundation

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
}
