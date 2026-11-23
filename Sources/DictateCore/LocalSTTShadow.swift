import Foundation

/// 1.29.19 (Archie 62.8.19): side by side. While the cloud answers a chunk as before, a copy of the same audio goes
/// to the on-device engine in the background; its answer is only counted — one log line with no text — and never
/// used. Text of either side goes only to the opt-in transcript trace. Nothing runs on the caller's path but a task
/// spawn. At most one chunk at the engine; a busy, slow, dead or missing engine changes nothing but the `result=`
/// value, and after an error or timeout the engine rests `rest` seconds. `end()` releases it once idle.
public final class LocalSTTShadow: @unchecked Sendable {
    public static let timeoutMs = 3_000
    public static let minimumAudioMs = 300
    public let path: String
    private let engine: (any LocalChunkSTT)?          // nil: helper or model missing
    private let release: @Sendable () -> Void
    private let mic: @Sendable () -> String
    private let log: @Sendable (String) -> Void
    private let rest: TimeInterval
    public var trace: (@Sendable (Int, String, String) -> Void)?    // (chunk, cloud text, local text)
    private let lock = NSLock()
    private var busy = false
    private var ended = false
    private var restingUntil = Date.distantPast

    public init(path: String, engine: (any LocalChunkSTT)?, release: @escaping @Sendable () -> Void = {},
                mic: @escaping @Sendable () -> String, log: @escaping @Sendable (String) -> Void, rest: TimeInterval = 30) {
        (self.path, self.engine, self.release, self.mic, self.log, self.rest) = (path, engine, release, mic, log, rest)
    }

    struct Outcome: Sendable { let audioMs: Int, mic: String, text: String, result: String, ms: Int }

    public final class Ticket: @unchecked Sendable {
        let index: Int
        let local: Task<Outcome?, Never>       // nil: not sent (silent, short, or after `end()`): no line
        init(_ index: Int, _ local: Task<Outcome?, Never>) { (self.index, self.local) = (index, local) }
    }

    /// Called before the chunk's cloud request; only spawns the background work and returns. After `end()`,
    /// nothing is sent.
    public func begin(index: Int, pcm16k: [Int16]) -> Ticket {
        let wasEnded = lock.withLock { ended }
        return Ticket(index, Task.detached(priority: .utility) { [self] in wasEnded ? nil : await run(pcm16k) })
    }

    /// The cloud's text for that chunk was used; the line is logged once the local side answers or times out.
    public func finish(_ ticket: Ticket?, cloudText: String, cloudMs: Int, provider: String) {
        guard let ticket else { return }
        Task.detached(priority: .utility) { [self] in
            guard let local = await ticket.local.value else { return }
            let cloudWords = Self.words(cloudText), localWords = Self.words(local.text)
            log("stt_shadow chunk=\(ticket.index) mic=\(local.mic) path=\(path) audio_ms=\(local.audioMs) local_ms=\(local.ms) "
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

    private func run(_ pcm16k: [Int16]) async -> Outcome? {
        let audioMs = pcm16k.count / 16
        guard audioMs >= Self.minimumAudioMs, pcm16k.contains(where: { abs(Int32($0)) >= 200 }) else { return nil }
        let mic = mic()
        guard let engine else { return Outcome(audioMs: audioMs, mic: mic, text: "", result: "helper_absent", ms: 0) }
        enum Admission { case run, busy, resting }
        let admission = lock.withLock { () -> Admission in
            if busy { return .busy }
            if Date() < restingUntil { return .resting }
            busy = true
            return .run
        }
        switch admission {
        case .busy: return Outcome(audioMs: audioMs, mic: mic, text: "", result: "local_skipped_busy", ms: 0)
        case .resting: return Outcome(audioMs: audioMs, mic: mic, text: "", result: "local_error", ms: 0)
        case .run: break
        }
        let answer = await Self.ask(engine, pcm16k)
        let releaseNow = lock.withLock { () -> Bool in
            busy = false
            if answer.result == "local_error" || answer.result == "local_timeout" { restingUntil = Date().addingTimeInterval(rest) }
            return ended
        }
        if releaseNow { release() }
        return Outcome(audioMs: audioMs, mic: mic, text: answer.text, result: answer.result, ms: answer.ms)
    }

    /// The helper loads its model on first use (not READY yet = `unavailable`): asked again until the deadline.
    /// At the deadline the engine is abandoned (a hung helper is killed, never queued behind).
    static func ask(_ engine: any LocalChunkSTT, _ pcm: [Int16]) async -> (text: String, result: String, ms: Int) {
        let start = DispatchTime.now().uptimeNanoseconds
        let outcome: Result<String, Error>? = await withTaskGroup(of: Result<String, Error>?.self) { group in
            group.addTask {
                while true {
                    do { return .success(try await engine.transcribe(pcm16k: pcm)) }
                    catch LocalSTTError.unavailable where !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
                    catch { return .failure(error) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                if !Task.isCancelled { engine.abandon() }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let ms = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        switch outcome {
        case .success(let text): return (text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "local_empty" : "ok", ms)
        case .failure: return ("", "local_error", ms)
        case nil: return ("", "local_timeout", ms)
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
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
