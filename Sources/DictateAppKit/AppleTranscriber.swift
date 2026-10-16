import AVFoundation
import Foundation
import Speech

/// G9: Apple's on-device SpeechAnalyzer (macOS 26). Audio is streamed in while
/// the user speaks; after the finish tap only finalisation is left (~20 ms
/// measured on the standard script). No network, no API key.
public final class AppleTranscriber: @unchecked Sendable {
    enum AppleError: Error { case unavailable, noFormat }

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var collector: Task<String, Error>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sourceFormat = try? NativePCM.format(.pcmFormatInt16, rate: AudioRecorder.sampleRate, channels: 1, interleaved: true)
    private var conversionFailure: Error?
    private let lock = NSLock()
    private var started = false
    private var pending: [[Int16]] = []

    public init() {
        transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (input, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Makes sure the on-device model is installed (no-op once it is).
    public static func ensureAssets() async {
        let probe = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try? await request.downloadAndInstall()
        }
    }

    public func start() async throws {
        guard let sourceFormat else { throw AppleError.noFormat }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppleError.noFormat
        }
        let preparedConverter = try NativePCM.converter(from: sourceFormat, to: format)
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
            converter = preparedConverter
            started = true
            defer { pending.removeAll() }
            return pending
        }
        for chunk in queued { feed(chunk) }
    }

    /// Thread-safe; chunks arriving before `start()` finishes are queued.
    public func append(_ samples: [Int16]) {
        let ready = lock.withLock { () -> Bool in
            if !started { pending.append(samples) }
            return started
        }
        if ready { feed(samples) }
    }

    private func feed(_ samples: [Int16]) {
        guard !samples.isEmpty, let sourceFormat,
              let (converter, format) = lock.withLock({ () -> (AVAudioConverter, AVAudioFormat)? in
                  guard let converter, let targetFormat else { return nil }
                  return (converter, targetFormat)
              }) else { return }
        do {
            let source = try NativePCM.buffer(sourceFormat, capacity: samples.count)
            source.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                source.int16ChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            let capacity = Int(Double(samples.count) * format.sampleRate / sourceFormat.sampleRate) + 64
            let out = try NativePCM.buffer(format, capacity: capacity)
            var fed = false
            _ = try NativePCM.convert(converter, to: out) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return source
            }
            if out.frameLength > 0 { inputContinuation.yield(AnalyzerInput(buffer: out)) }
        } catch {
            lock.withLock { conversionFailure = error }
            inputContinuation.finish()
        }
    }

    /// Finalises and returns the full transcript.
    public func finish() async throws -> String {
        inputContinuation.finish()
        if let failure = lock.withLock({ conversionFailure }) {
            await analyzer.cancelAndFinishNow()
            collector?.cancel()
            throw failure
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        guard let collector else { throw AppleError.unavailable }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() {
        inputContinuation.finish()
        collector?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}
