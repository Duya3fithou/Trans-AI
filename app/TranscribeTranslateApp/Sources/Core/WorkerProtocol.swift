import Foundation

enum WorkerCommandType: String, Codable {
    case downloadModels
    case warmup
    case processAudio
    case stop
}

struct WorkerCommand: Codable {
    let type: WorkerCommandType
    let targetLanguage: String?
    let modelRoot: String?
    let audioBase64: String?
    let sampleRate: Int?
    let channels: Int?
}

enum WorkerEventType: String, Codable {
    case status
    case downloadProgress
    case segment
    case error
}

struct WorkerSegmentPayload: Codable {
    let segment_id: String
    let start_seconds: Double
    let end_seconds: Double
    let source_text: String
    let translated_text: String
}

struct WorkerEvent: Codable {
    let type: WorkerEventType
    let message: String?
    let progress: Double?
    let segment: WorkerSegmentPayload?
}
