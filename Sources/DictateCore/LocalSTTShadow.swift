import Foundation

/// 1.29.19 (Archie 62.8.19): side by side. While the cloud answers a chunk as before, a copy of the same audio goes
/// to the on-device engine in the background; its answer is only counted — one log line with no text — and never
/// used. Text of either side goes only to the opt-in transcript trace. At most one chunk at the engine; a busy,
/// slow, dead or missing engine changes nothing but the `result=` value. `end()` releases the engine once idle.
public final class LocalSTTShadow: @unchecked Sendable {
    public static let timeoutMs = 3_000
    public static let minimumAudioMs = 300
    public let path: String
    private let engine: (any LocalChunkSTT)?          // nil: helper or model missing
    private let release: @Sendable () -> Void
    private let mic: @Sendable () -> String
    private let log: @Sendable (String) -> Void
    public var trace: (@Sendable (Int, String, String) -> Void)?    // (chunk, cloud text, local text)
    private let lock = NSLock()
    private var busy = false
    private var ended = false

    public init(path: String, engine: (any LocalChunkSTT)?, release: @escaping @Sendable () -> Void = {},
                mic: @escaping @Sendable () -> String, log: @escaping @Sendable (String) -> Void) {
        (self.path, self.engine, self.release, self.mic, self.log) = (path, engine, release, mic, log)
    }

    public final class Ticket: @unchecked Sendable {
        let index: Int, audioMs: Int, mic: String
        let local: Task<(text: String, result: String, ms: Int), Never>?
        let result: String
        init(_ index: Int, _ audioMs: Int, _ mic: String, local: Task<(text: String, result: String, ms: Int), Never>?, result: String) {
            (self.index, self.audioMs, self.mic, self.local, self.result) = (index, audioMs, mic, local, result)
        }
    }

    /// Called before the chunk's cloud request; never waits. Nil (nothing sent, no line): a silent or short chunk.
    public func begin(index: Int, pcm16k: [Int16]) -> Ticket? {
        let audioMs = pcm16k.count / 16
        guard audioMs >= Self.minimumAudioMs, pcm16k.contains(where: { abs(Int32($0)) >= 200 }) else { return nil }
        let mic = mic()
        guard let engine else { return Ticket(index, audioMs, mic, local: nil, result: "helper_absent") }
        let admitted = lock.withLock { () -> Bool in
            guard !busy else { return false }
            (busy, ended) = (true, false)
            return true
        }
        guard admitted else { return Ticket(index, audioMs, mic, local: nil, result: "local_skipped_busy") }
        let task = Task.detached { [self] () -> (text: String, result: String, ms: Int) in
            defer { idle() }
            return await Self.ask(engine, pcm16k)
        }
        return Ticket(index, audioMs, mic, local: task, result: "")
    }

    /// The cloud's text for that chunk was used; the line is logged once the local side answers or times out.
    public func finish(_ ticket: Ticket?, cloudText: String, cloudMs: Int, provider: String) {
        guard let ticket else { return }
        Task.detached { [self] in
            let local = await ticket.local?.value ?? (text: "", result: ticket.result, ms: 0)
            let cloudWords = Self.words(cloudText), localWords = Self.words(local.text)
            log("stt_shadow chunk=\(ticket.index) mic=\(ticket.mic) path=\(path) audio_ms=\(ticket.audioMs) local_ms=\(local.ms) "
                + "cloud_ms=\(cloudMs) cloud_provider=\(provider) words_cloud=\(cloudWords.count) words_local=\(localWords.count) "
                + "words_differ=\(Self.distance(cloudWords, localWords)) result=\(local.result)")
            if local.result == "ok" || local.result == "local_empty" { trace?(ticket.index, cloudText, local.text) }
        }
    }

    /// The conversation or dictation ended: the engine is released now, or when its chunk in flight finishes.
    public func end() {
        let now = lock.withLock { ended = true; return !busy }
        if now { release() }
    }

    deinit { release() }

    private func idle() {
        let releaseNow = lock.withLock { busy = false; return ended }
        if releaseNow { release() }
    }

    /// The helper loads its model on first use (not READY yet = `unavailable`): retried for up to a second.
    static func ask(_ engine: any LocalChunkSTT, _ pcm: [Int16]) async -> (text: String, result: String, ms: Int) {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
        typealias Answer = (result: Result<String, Error>, start: UInt64)
        let answer: Answer? = await withTaskGroup(of: Answer?.self) { group in
            group.addTask {
                for attempt in 0...20 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    do { return (.success(try await engine.transcribe(pcm16k: pcm)), start) }
                    catch LocalSTTError.unavailable where attempt < 20 { try? await Task.sleep(nanoseconds: 50_000_000) }
                    catch { return (.failure(error), start) }
                }
                return nil
            }
            group.addTask {
                let now = DispatchTime.now().uptimeNanoseconds
                try? await Task.sleep(nanoseconds: deadline > now ? deadline - now : 0)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let ms = answer.map { Int((DispatchTime.now().uptimeNanoseconds - $0.start) / 1_000_000) } ?? timeoutMs
        let outcome = answer?.result
        switch outcome {
        case .success(let text): return (text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "local_empty" : "ok", ms)
        case .failure: return ("", "local_error", ms)
        case nil: engine.abandon(); return ("", "local_timeout", ms)    // a hung helper is killed, never queued behind
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    /// Word-level edit distance (substitutions + insertions + deletions).
    static func distance(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var previous = row[0]; row[0] = i + 1
            for (j, y) in b.enumerated() {
                let next = min(row[j + 1] + 1, row[j] + 1, previous + (x == y ? 0 : 1))
                previous = row[j + 1]; row[j + 1] = next
            }
        }
        return row[b.count]
    }
}
