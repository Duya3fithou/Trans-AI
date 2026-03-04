import Foundation

struct TranscriptRecord: Identifiable {
    let id = UUID()
    let segmentID: String
    let startSeconds: Double
    let endSeconds: Double
    let sourceText: String
    let translatedText: String
}
