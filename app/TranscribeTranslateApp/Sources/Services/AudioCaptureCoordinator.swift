import AVFAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioCaptureCoordinator: NSObject {
    var onAudioChunk: ((Data) -> Void)?
    var onCaptureError: ((String) -> Void)?

    private(set) var isCapturing = false

    private let processingQueue = DispatchQueue(label: "com.example.TranscribeTranslateApp.audio.processing")
    private let targetSampleRate: Double = 16_000
    private let targetChannels: AVAudioChannelCount = 1

    private var stream: SCStream?
    private var microphoneEngine: AVAudioEngine?
    private let mixer = PCMChunkMixer(chunkSizeBytes: 16_000)

    func startCapture() async throws {
        guard !isCapturing else { return }

        guard await requestScreenCapturePermission() else {
            throw AudioCaptureError.screenCapturePermissionDenied
        }

        guard await requestMicrophonePermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareableContent.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = false

        // Video frames are not consumed in this app, but stream still needs a valid configuration.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)

        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)

        if #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: processingQueue)
        } else {
            try startLegacyMicrophoneFallback()
        }

        try await stream.startCapture()

        self.stream = stream
        self.isCapturing = true
    }

    func stopCapture() {
        isCapturing = false
        stopLegacyMicrophoneFallback()

        let activeStream = stream
        stream = nil

        guard let activeStream else { return }
        Task {
            try? await activeStream.stopCapture()
        }
    }

    private func requestScreenCapturePermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    private func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted {
            return true
        }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startLegacyMicrophoneFallback() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let data = self.convertBufferToTargetPCM(buffer: buffer) else { return }
            self.mixer.append(data: data, source: .microphone) { [weak self] mixed in
                self?.emitChunk(mixed)
            }
        }

        try engine.start()
        microphoneEngine = engine
    }

    private func stopLegacyMicrophoneFallback() {
        guard let engine = microphoneEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        microphoneEngine = nil
    }

    private func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer, source: PCMChunkMixer.Source) {
        guard let data = convertSampleBufferToTargetPCM(sampleBuffer) else { return }
        mixer.append(data: data, source: source) { [weak self] mixed in
            self?.emitChunk(mixed)
        }
    }

    private func emitChunk(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.onAudioChunk?(data)
        }
    }

    private func convertSampleBufferToTargetPCM(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: asbdPointer),
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(numSamples)
              )
        else {
            return nil
        }

        sourceBuffer.frameLength = sourceBuffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: sourceBuffer.mutableAudioBufferList
        )

        guard status == noErr else { return nil }
        return convertBufferToTargetPCM(buffer: sourceBuffer)
    }

    private func convertBufferToTargetPCM(buffer: AVAudioPCMBuffer) -> Data? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        ) else {
            return nil
        }

        let inputRate = buffer.format.sampleRate
        guard inputRate > 0 else { return nil }

        let estimatedFrameCount = AVAudioFrameCount((Double(buffer.frameLength) * targetSampleRate / inputRate).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrameCount),
              let converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        else {
            return nil
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error,
              error == nil,
              outputBuffer.frameLength > 0
        else {
            return nil
        }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData,
              audioBuffer.mDataByteSize > 0
        else {
            return nil
        }

        return Data(bytes: mData, count: Int(audioBuffer.mDataByteSize))
    }
}

extension AudioCaptureCoordinator: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        if outputType == .screen {
            return
        }

        if outputType == .audio {
            handleAudioBuffer(sampleBuffer, source: .system)
            return
        }

        if #available(macOS 15.0, *), outputType == .microphone {
            handleAudioBuffer(sampleBuffer, source: .microphone)
        }
    }
}

extension AudioCaptureCoordinator: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturing = false
        stopLegacyMicrophoneFallback()
        Task { @MainActor [weak self] in
            self?.onCaptureError?("Capture stopped: \(error.localizedDescription)")
        }
    }
}

private final class PCMChunkMixer {
    enum Source {
        case system
        case microphone
    }

    private let chunkSizeBytes: Int
    private var systemBuffer = Data()
    private var microphoneBuffer = Data()

    init(chunkSizeBytes: Int) {
        self.chunkSizeBytes = chunkSizeBytes
    }

    func append(data: Data, source: Source, onMixedChunk: (Data) -> Void) {
        switch source {
        case .system:
            systemBuffer.append(data)
        case .microphone:
            microphoneBuffer.append(data)
        }

        while systemBuffer.count >= chunkSizeBytes || microphoneBuffer.count >= chunkSizeBytes {
            let systemChunk = dequeueChunk(from: &systemBuffer)
            let microphoneChunk = dequeueChunk(from: &microphoneBuffer)
            onMixedChunk(mix(systemChunk, microphoneChunk))
        }
    }

    private func dequeueChunk(from buffer: inout Data) -> Data {
        if buffer.count >= chunkSizeBytes {
            let chunk = buffer.prefix(chunkSizeBytes)
            buffer.removeFirst(chunkSizeBytes)
            return Data(chunk)
        }

        var padded = Data(buffer)
        padded.append(Data(repeating: 0, count: chunkSizeBytes - buffer.count))
        buffer.removeAll(keepingCapacity: true)
        return padded
    }

    private func mix(_ first: Data, _ second: Data) -> Data {
        let sampleCount = min(first.count, second.count) / MemoryLayout<Int16>.size
        var mixed = Data(count: sampleCount * MemoryLayout<Int16>.size)

        first.withUnsafeBytes { firstRaw in
            second.withUnsafeBytes { secondRaw in
                mixed.withUnsafeMutableBytes { outRaw in
                    guard let firstBase = firstRaw.baseAddress,
                          let secondBase = secondRaw.baseAddress,
                          let outBase = outRaw.baseAddress
                    else {
                        return
                    }

                    let firstSamples = firstBase.bindMemory(to: Int16.self, capacity: sampleCount)
                    let secondSamples = secondBase.bindMemory(to: Int16.self, capacity: sampleCount)
                    let outSamples = outBase.bindMemory(to: Int16.self, capacity: sampleCount)

                    for index in 0..<sampleCount {
                        let sum = Int(firstSamples[index]) + Int(secondSamples[index])
                        outSamples[index] = Int16(clamping: sum / 2)
                    }
                }
            }
        }

        return mixed
    }
}

enum AudioCaptureError: LocalizedError {
    case screenCapturePermissionDenied
    case microphonePermissionDenied
    case noDisplayFound

    var errorDescription: String? {
        switch self {
        case .screenCapturePermissionDenied:
            return "Screen Recording permission was not granted."
        case .microphonePermissionDenied:
            return "Microphone permission was not granted."
        case .noDisplayFound:
            return "No display found for screen capture."
        }
    }
}
