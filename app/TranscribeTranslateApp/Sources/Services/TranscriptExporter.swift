import Foundation

@MainActor
final class TranscriptExporter {
    func export(records: [TranscriptRecord]) throws -> URL {
        let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("TranscribeTranslate", isDirectory: true)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "meeting_\(formatter.string(from: Date())).md"
        let outputFile = outputDirectory.appendingPathComponent(filename)

        var content = "# Meeting Transcript\n\n"
        for record in records {
            content += "## [\(timestamp(record.startSeconds)) - \(timestamp(record.endSeconds))]\n"
            content += "- Source: \(record.sourceText)\n"
            content += "- Translation: \(record.translatedText)\n\n"
        }

        try content.write(to: outputFile, atomically: true, encoding: .utf8)
        return outputFile
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
