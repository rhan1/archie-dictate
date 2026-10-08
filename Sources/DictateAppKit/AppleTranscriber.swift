import AVFoundation
import Foundation
import Speech

/// G9: Apple's on-device SpeechAnalyzer (macOS 26). Audio is streamed in while
/// the user speaks; after the finish tap only finalisation is left (~20 ms
/// measured on the standard script). No network, no API key.
final class AppleTranscriber: @unchecked Sendable {
    enum AppleError: Error { case unavailable, noFormat }

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var collector: Task<String, Error>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var started = false
    private var pending: [[Int16]] = []

    init() {
        transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (input, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Makes sure the on-device model is installed (no-op once it is).
    static func ensureAssets() async {
        let probe = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try? await request.downloadAndInstall()
        }
    }

    func start() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleError.noFormat
        }
        let transcriber = self.transcriber
        collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        try await analyzer.start(inputSequence: input)
        let queued: [[Int16]] = lock.withLock {
            targetFormat = format
            converter = AVAudioConverter(from: sourceFormat, to: format)
            started = true
            defer { pending.removeAll() }
            return pending
        }
        for chunk in queued { feed(chunk) }
    }

    /// Thread-safe; chunks arriving before `start()` finishes are queued.
    func append(_ samples: [Int16]) {
        let ready = lock.withLock { () -> Bool in
            if !started { pending.append(samples) }
            return started
        }
        if ready { feed(samples) }
    }

    private func feed(_ samples: [Int16]) {
        guard !samples.isEmpty,
              let (converter, format) = lock.withLock({ () -> (AVAudioConverter, AVAudioFormat)? in
                  guard let converter, let targetFormat else { return nil }
                  return (converter, targetFormat)
              }),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            source.int16ChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / sourceFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        if out.frameLength > 0 { inputContinuation.yield(AnalyzerInput(buffer: out)) }
    }

    /// Finalises and returns the full transcript.
    func finish() async throws -> String {
        inputContinuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        guard let collector else { throw AppleError.unavailable }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        inputContinuation.finish()
        collector?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}
