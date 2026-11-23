import Foundation
import Testing
@testable import DictateCore

/// archie-62819 (Dictate 1.29.19): side-by-side shadow engine (`LocalSTTShadow`).
/// Never delays or alters the cloud path; logs counts only (no transcript text).
private actor FakeShadowCloudHTTP: HTTPTransport {
    let text: String
    let delayMs: Int
    private(set) var requests = 0

    init(text: String = "hello there world", delayMs: Int = 10) {
        self.text = text
        self.delayMs = delayMs
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class FakeShadowLocal: LocalChunkSTT, @unchecked Sendable {
    enum Mode: Sendable {
        case text(String)
        case delay(milliseconds: Int, text: String)
        case fail(Error)
    }

    let modelID = "fake-shadow-local"
    private let mode: Mode
    private let lock = NSLock()
    private var _calls = 0
    private var _abandonCalls = 0

    init(_ mode: Mode) { self.mode = mode }

    var calls: Int { lock.withLock { _calls } }
    var abandonCalls: Int { lock.withLock { _abandonCalls } }

    func transcribe(pcm16k: [Int16]) async throws -> String {
        lock.withLock { _calls += 1 }
        switch mode {
        case .text(let text):
            return text
        case .delay(let ms, let text):
            try await Task.sleep(for: .milliseconds(ms))
            return text
        case .fail(let error):
            throw error
        }
    }

    func abandon() {
        lock.withLock { _abandonCalls += 1 }
    }
}

private final class HungCancelableLocal: LocalChunkSTT, @unchecked Sendable {
    let modelID = "fake-hung-local"
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var cancelled = false
    private var _abandonCalls = 0
    private let events: LockedList<String>

    init(events: LockedList<String>) { self.events = events }

    var abandonCalls: Int { lock.withLock { _abandonCalls } }

    func transcribe(pcm16k: [Int16]) async throws -> String {
        defer { events.append("chunk_finished") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let resumeImmediately = lock.withLock { () -> Bool in
                    if cancelled { return true }
                    continuation = cont
                    return false
                }
                if resumeImmediately { cont.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let cont = lock.withLock { () -> CheckedContinuation<String, Error>? in
                cancelled = true
                defer { continuation = nil }
                return continuation
            }
            cont?.resume(throwing: CancellationError())
        }
    }

    func abandon() {
        lock.withLock { _abandonCalls += 1 }
        events.append("abandon")
    }
}

private final class LockedList<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) { lock.withLock { items.append(item) } }
    var all: [Element] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            _value += 1
            return _value
        }
    }

    var value: Int { lock.withLock { _value } }
}

@Suite("A62819LocalSTTShadowTests", .serialized)
struct A62819LocalSTTShadowTests {
    /// 1 s of non-silent 24 kHz PCM (resamples to 16,000 samples / 1,000 ms at 16 kHz).
    private static func voiced24k(seconds: Double = 1.0) -> [Int16] {
        let count = Int((seconds * Double(PauseChunker.sampleRate)).rounded())
        return (0..<count).map { Int16(4_000 * sin(2 * .pi * 330 * Double($0) / Double(PauseChunker.sampleRate))) }
    }

    /// ≥ 300 ms of 16 kHz PCM with amplitude ≥ 1000.
    private static func voiced16k(milliseconds: Int = 500, amplitude: Int16 = 2_000) -> [Int16] {
        let count = milliseconds * 16
        return (0..<count).map { Int16(Double(amplitude) * sin(2 * .pi * 330 * Double($0) / 16_000.0)) }
    }

    private static func waitUntil(timeoutSeconds: Double = 6.0, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1_000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1_000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func runTwoChunks(shadow: LocalSTTShadow?, logs: LockedList<String>) async -> GroqChunkedTranscriber.Result {
        let cloud = FakeShadowCloudHTTP(text: "hello there world", delayMs: 10)
        let transcriber = GroqChunkedTranscriber(
            transport: cloud, apiKey: { "groq-key" }, prompt: "Archie",
            fillerLeadIn: false, shadow: shadow
        )
        let t0 = transcriber.submit(PauseChunker.Chunk(index: 0, samples: voiced24k(), cutKind: .pause, quietRunMs: 250))
        await t0?.value
        if shadow != nil { _ = await waitUntil(timeoutSeconds: 3.0) { logs.count >= 1 } }
        let t1 = transcriber.submit(PauseChunker.Chunk(index: 1, samples: voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
        await t1?.value
        return await transcriber.finish()
    }

    @Test func shadow_logs_one_line_per_chunk() async {
        let logs = LockedList<String>()
        let local = FakeShadowLocal(.text("hello their world"))
        let shadow = LocalSTTShadow(path: "conversation", engine: local, mic: { "builtin" }, log: { logs.append($0) })
        let result = await Self.runTwoChunks(shadow: shadow, logs: logs)
        let logged = await Self.waitUntil(timeoutSeconds: 6.0) { logs.count == 2 }
        let lines = logs.all
        let expectedFields = lines.count == 2 && lines.enumerated().allSatisfy { idx, line in
            line.contains("stt_shadow chunk=\(idx)")
                && line.contains("result=ok")
                && line.contains("words_cloud=3 words_local=3 words_differ=1")
                && line.contains("cloud_provider=groq")
                && line.contains("path=conversation")
                && line.contains("mic=builtin")
        }
        let ok = logged && !result.text.isEmpty && expectedFields
        print("P \(ok ? "GREEN" : "RED") shadow_logs_one_line_per_chunk lines=\(lines.count)")
        #expect(ok)
    }

    @Test func shadow_logs_one_line_per_chunk_red_base() async {
        let logs = LockedList<String>()
        let result = await Self.runTwoChunks(shadow: nil, logs: logs)
        try? await Task.sleep(for: .milliseconds(50))
        let lines = logs.all
        let ok = lines.isEmpty && !result.text.isEmpty
        if lines.isEmpty {
            print("P RED shadow_logs_one_line_per_chunk lines=0 (shadow nil = base)")
        } else {
            print("P GREEN shadow_logs_one_line_per_chunk lines=\(lines.count)")
        }
        #expect(ok)
    }

    /// The real path's text arrives at the base time while the helper sleeps 5 s: 5 alternating runs, medians.
    @Test func shadow_never_delays_real_path() async {
        let logs = LockedList<String>()
        var baseRuns: [Int] = [], realRuns: [Int] = [], texts: Set<String> = []
        for _ in 0..<5 {
            for shadowed in [false, true] {
                let shadow = shadowed ? LocalSTTShadow(path: "conversation", engine: FakeShadowLocal(.delay(milliseconds: 5_000, text: "too slow")),
                                                       mic: { "builtin" }, log: { logs.append($0) }) : nil
                let transcriber = GroqChunkedTranscriber(transport: FakeShadowCloudHTTP(text: "hello there world", delayMs: 25),
                                                         apiKey: { "groq-key" }, prompt: "Archie", fillerLeadIn: false, shadow: shadow)
                let start = ContinuousClock.now
                transcriber.submit(PauseChunker.Chunk(index: 0, samples: Self.voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
                let result = await transcriber.finish()
                texts.insert(result.text)
                if shadowed { realRuns.append(Self.elapsedMs(since: start)) } else { baseRuns.append(Self.elapsedMs(since: start)) }
            }
        }
        let median = { (runs: [Int]) in runs.sorted()[runs.count / 2] }
        let logged = await Self.waitUntil(timeoutSeconds: 8.0) { logs.count == 5 }
        let ok = texts.count == 1 && texts.first?.isEmpty == false && median(realRuns) <= median(baseRuns) + 100
            && logged && logs.all.allSatisfy { $0.contains("result=local_timeout") }
        print("P \(ok ? "GREEN" : "RED") shadow_never_delays_real_path=\(ok ? 1 : 0) real_ms_p50=\(median(realRuns)) base_ms_p50=\(median(baseRuns)) real=\(realRuns) base=\(baseRuns)")
        #expect(ok)
    }

    @Test func shadow_helper_crash_real_path_unchanged() async {
        let baseCloud = FakeShadowCloudHTTP(text: "hello there world", delayMs: 10)
        let baseTranscriber = GroqChunkedTranscriber(
            transport: baseCloud, apiKey: { "groq-key" }, prompt: "Archie",
            fillerLeadIn: false, shadow: nil
        )
        baseTranscriber.submit(PauseChunker.Chunk(index: 0, samples: Self.voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
        let baseResult = await baseTranscriber.finish()

        let logs = LockedList<String>()
        let crashingLocal = FakeShadowLocal(.fail(LocalSTTError.exited))
        let shadow = LocalSTTShadow(path: "conversation", engine: crashingLocal, mic: { "builtin" }, log: { logs.append($0) })
        let realCloud = FakeShadowCloudHTTP(text: "hello there world", delayMs: 10)
        let realTranscriber = GroqChunkedTranscriber(
            transport: realCloud, apiKey: { "groq-key" }, prompt: "Archie",
            fillerLeadIn: false, shadow: shadow
        )
        realTranscriber.submit(PauseChunker.Chunk(index: 0, samples: Self.voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
        let realResult = await realTranscriber.finish()

        let logged = await Self.waitUntil(timeoutSeconds: 6.0) { logs.count == 1 }
        let line = logs.all.first ?? ""
        let ok = realResult.text == baseResult.text && logged && line.contains("result=local_error")
        print("P \(ok ? "GREEN" : "RED") shadow_helper_crash_real_path_unchanged=\(ok ? 1 : 0)")
        #expect(ok)
    }

    @Test func shadow_hang_then_turn_end_releases_helper() async {
        let baseCloud = FakeShadowCloudHTTP(text: "hello there world", delayMs: 10)
        let baseTranscriber = GroqChunkedTranscriber(
            transport: baseCloud, apiKey: { "groq-key" }, prompt: "Archie",
            fillerLeadIn: false, shadow: nil
        )
        baseTranscriber.submit(PauseChunker.Chunk(index: 0, samples: Self.voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
        let baseResult = await baseTranscriber.finish()

        let logs = LockedList<String>()
        let events = LockedList<String>()
        let releases = LockedCounter()
        let hungLocal = HungCancelableLocal(events: events)
        let shadow = LocalSTTShadow(
            path: "conversation",
            engine: hungLocal,
            release: {
                events.append("release")
                releases.increment()
            },
            mic: { "builtin" },
            log: { logs.append($0) }
        )

        let cloud = FakeShadowCloudHTTP(text: "hello there world", delayMs: 10)
        let transcriber = GroqChunkedTranscriber(
            transport: cloud, apiKey: { "groq-key" }, prompt: "Archie",
            fillerLeadIn: false, shadow: shadow
        )
        let start = ContinuousClock.now
        transcriber.submit(PauseChunker.Chunk(index: 0, samples: Self.voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
        let realResult = await transcriber.finish()
        let finishMs = Self.elapsedMs(since: start)
        shadow.end()

        // Release must not run while the hung chunk is still in flight.
        let releasedBeforeFinish = releases.value != 0
        let settled = await Self.waitUntil(timeoutSeconds: 4.0) { logs.count == 1 && releases.value >= 1 }
        let orderedEvents = events.all
        let finishIndex = orderedEvents.firstIndex(of: "chunk_finished")
        let firstReleaseIndex = orderedEvents.firstIndex(of: "release")
        let releaseAfterChunk = if let finishIndex, let firstReleaseIndex { firstReleaseIndex > finishIndex } else { false }
        let line = logs.all.first ?? ""

        let ok = realResult.text == baseResult.text
            && finishMs < 500
            && !releasedBeforeFinish
            && settled
            && line.contains("result=local_timeout")
            && hungLocal.abandonCalls == 1
            && releases.value >= 1
            && releaseAfterChunk
        print("P \(ok ? "GREEN" : "RED") shadow_hang_then_turn_end_releases_helper=\(ok ? 1 : 0)")
        #expect(ok)
    }

    @Test func shadow_busy_skips_late_chunk() async {
        let logs = LockedList<String>()
        let slowLocal = FakeShadowLocal(.delay(milliseconds: 1_000, text: "slow local"))
        let shadow = LocalSTTShadow(path: "conversation", engine: slowLocal, mic: { "builtin" }, log: { logs.append($0) })
        let pcm = Self.voiced16k(milliseconds: 500, amplitude: 2_000)

        let first = shadow.begin(index: 0, pcm16k: pcm)
        let second = shadow.begin(index: 1, pcm16k: pcm)
        shadow.finish(first, cloudText: "slow cloud", cloudMs: 20, provider: "groq")
        shadow.finish(second, cloudText: "slow cloud", cloudMs: 20, provider: "groq")

        let logged = await Self.waitUntil(timeoutSeconds: 6.0) { logs.count == 2 }
        let lines = logs.all
        let hasOk = lines.contains { $0.contains("result=ok") }
        let hasBusy = lines.contains { $0.contains("result=local_skipped_busy") }
        let ok = first != nil && second != nil && logged && hasOk && hasBusy
        print("P \(ok ? "GREEN" : "RED") shadow_busy_skips_late_chunk=\(ok ? 1 : 0)")
        #expect(ok)
    }

    @Test func shadow_short_or_silent_chunk_not_sent() async {
        let logs = LockedList<String>()
        let local = FakeShadowLocal(.text("should not run"))
        let shadow = LocalSTTShadow(path: "conversation", engine: local, mic: { "builtin" }, log: { logs.append($0) })

        let shortTicket = shadow.begin(index: 0, pcm16k: Self.voiced16k(milliseconds: 200, amplitude: 2_000))
        let silentTicket = shadow.begin(index: 1, pcm16k: [Int16](repeating: 0, count: 16_000))
        shadow.finish(shortTicket, cloudText: "ignored", cloudMs: 10, provider: "groq")
        shadow.finish(silentTicket, cloudText: "ignored", cloudMs: 10, provider: "groq")
        try? await Task.sleep(for: .milliseconds(50))

        try? await Task.sleep(nanoseconds: 300_000_000)
        let ok = local.calls == 0 && logs.count == 0
        print("P \(ok ? "GREEN" : "RED") shadow_short_or_silent_chunk_not_sent=\(ok ? 1 : 0)")
        #expect(ok)
    }

    @Test func shadow_text_never_logged() async {
        let logs = LockedList<String>()
        let traced = LockedList<(Int, String, String)>()
        let local = FakeShadowLocal(.text("zebra quantum marmalades"))
        let shadow = LocalSTTShadow(path: "conversation", engine: local, mic: { "builtin" }, log: { logs.append($0) })
        shadow.trace = { index, cloud, local in traced.append((index, cloud, local)) }

        let cloud = FakeShadowCloudHTTP(text: "zebra quantum marmalade", delayMs: 10)
        let transcriber = GroqChunkedTranscriber(
            transport: cloud, apiKey: { "groq-key" }, prompt: "Archie",
            fillerLeadIn: false, shadow: shadow
        )
        transcriber.submit(PauseChunker.Chunk(index: 0, samples: Self.voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
        _ = await transcriber.finish()

        let settled = await Self.waitUntil(timeoutSeconds: 6.0) { logs.count == 1 && traced.count == 1 }
        let forbidden = ["zebra", "quantum", "marmalade"]
        let leaked = logs.all.contains { line in
            let lowered = line.lowercased()
            return forbidden.contains { lowered.contains($0) }
        }
        let traces = traced.all
        let traceMatches = traces.count == 1
            && traces[0].0 == 0
            && traces[0].1 == "zebra quantum marmalade"
            && traces[0].2 == "zebra quantum marmalades"
        let ok = settled && !leaked && traceMatches
        print("P \(ok ? "GREEN" : "RED") shadow_text_never_logged=\(ok ? 1 : 0)")
        #expect(ok)
    }

    @Test func local_on_disables_shadow() async {
        let logs = LockedList<String>()
        let realLocal = FakeShadowLocal(.text("from local"))
        let shadowEngine = FakeShadowLocal(.text("from shadow"))
        let shadow = LocalSTTShadow(path: "dictation", engine: shadowEngine, mic: { "builtin" }, log: { logs.append($0) })
        let cloud = FakeShadowCloudHTTP(text: "from cloud", delayMs: 10)
        let transcriber = GroqChunkedTranscriber(
            transport: cloud, apiKey: { "groq-key" }, prompt: "Archie",
            fillerLeadIn: false, local: realLocal, shadow: shadow
        )
        transcriber.submit(PauseChunker.Chunk(index: 0, samples: Self.voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
        let result = await transcriber.finish()
        try? await Task.sleep(for: .milliseconds(50))

        let ok = result.text == "from local" && logs.count == 0 && shadowEngine.calls == 0
        print("P \(ok ? "GREEN" : "RED") local_on_disables_shadow=\(ok ? 1 : 0)")
        #expect(ok)
    }

    @Test func helper_absent() async {
        let logs = LockedList<String>()
        let shadow = LocalSTTShadow(path: "conversation", engine: nil, mic: { "builtin" }, log: { logs.append($0) })
        let ticket = shadow.begin(index: 0, pcm16k: Self.voiced16k(milliseconds: 500, amplitude: 2_000))
        shadow.finish(ticket, cloudText: "hello world", cloudMs: 25, provider: "groq")

        let logged = await Self.waitUntil(timeoutSeconds: 6.0) { logs.count == 1 }
        let line = logs.all.first ?? ""
        let ok = ticket != nil
            && logged
            && line.contains("result=helper_absent")
            && line.contains("words_local=0")
        print("P \(ok ? "GREEN" : "RED") helper_absent=\(ok ? 1 : 0)")
        #expect(ok)
    }

    @Test func words_and_distance() {
        let words = LocalSTTShadow.words("Hello, world!")
        let dist = LocalSTTShadow.distance(["a", "b", "c"], ["a", "x", "c", "d"])
        let ok = words == ["hello", "world"] && dist == 2
        print("P \(ok ? "GREEN" : "RED") words_and_distance=\(ok ? 1 : 0)")
        #expect(ok)
    }

    // MARK: - fix pass (Fable M1 / Codex BLOCKER + MAJORs)

    /// Nothing of the shadow runs before the cloud request: a mic lookup that blocks 1 s costs the real path nothing.
    @Test func shadow_slow_mic_never_delays_real_path() async {
        var base: [Int] = [], real: [Int] = []
        for _ in 0..<3 {
            for shadowed in [false, true] {
                let shadow = shadowed ? LocalSTTShadow(path: "conversation", engine: FakeShadowLocal(.text("x")),
                                                       mic: { Thread.sleep(forTimeInterval: 1.0); return "builtin" }, log: { _ in }) : nil
                let transcriber = GroqChunkedTranscriber(transport: FakeShadowCloudHTTP(text: "hello there world", delayMs: 25),
                                                         apiKey: { "groq-key" }, prompt: "Archie", fillerLeadIn: false, shadow: shadow)
                let start = ContinuousClock.now
                transcriber.submit(PauseChunker.Chunk(index: 0, samples: Self.voiced24k(), cutKind: .final, quietRunMs: nil), isFinal: true)
                _ = await transcriber.finish()
                if shadowed { real.append(Self.elapsedMs(since: start)) } else { base.append(Self.elapsedMs(since: start)) }
            }
        }
        let median = { (runs: [Int]) in runs.sorted()[runs.count / 2] }
        let ok = median(real) <= median(base) + 100
        print("P \(ok ? "GREEN" : "RED") shadow_slow_mic_never_delays_real_path=\(ok ? 1 : 0) real_ms_p50=\(median(real)) base_ms_p50=\(median(base)) real=\(real) base=\(base)")
        #expect(ok)
    }

    /// After `end()` (conversation closed) a late chunk starts nothing and logs nothing.
    @Test func shadow_after_end_sends_nothing() async {
        let logs = LockedList<String>(), releases = LockedList<Int>()
        let local = FakeShadowLocal(.text("late"))
        let shadow = LocalSTTShadow(path: "conversation", engine: local, release: { releases.append(1) }, mic: { "builtin" }, log: { logs.append($0) })
        shadow.end()
        shadow.finish(shadow.begin(index: 7, pcm16k: Self.voiced16k()), cloudText: "late chunk", cloudMs: 5, provider: "groq")
        try? await Task.sleep(nanoseconds: 400_000_000)
        let ok = local.calls == 0 && logs.count == 0 && releases.count == 1
        print("P \(ok ? "GREEN" : "RED") shadow_after_end_sends_nothing=\(ok ? 1 : 0) engine_calls=\(local.calls) lines=\(logs.count) releases=\(releases.count)")
        #expect(ok)
    }

    /// A helper that fails is not asked again for `rest` seconds: the next chunk logs local_error without a call.
    @Test func shadow_rests_after_failure() async {
        let logs = LockedList<String>()
        let local = FakeShadowLocal(.fail(LocalSTTError.exited))
        let shadow = LocalSTTShadow(path: "dictation", engine: local, mic: { "headset" }, log: { logs.append($0) })
        shadow.finish(shadow.begin(index: 0, pcm16k: Self.voiced16k()), cloudText: "one two", cloudMs: 5, provider: "groq")
        _ = await Self.waitUntil(timeoutSeconds: 3) { logs.count == 1 }
        shadow.finish(shadow.begin(index: 1, pcm16k: Self.voiced16k()), cloudText: "three four", cloudMs: 5, provider: "groq")
        _ = await Self.waitUntil(timeoutSeconds: 3) { logs.count == 2 }
        let ok = local.calls == 1 && logs.all.count == 2 && logs.all.allSatisfy { $0.hasSuffix("result=local_error") }
        print("P \(ok ? "GREEN" : "RED") shadow_rests_after_failure=\(ok ? 1 : 0) engine_calls=\(local.calls)")
        #expect(ok)
    }

    /// An engine that ignores cancellation is abandoned at the deadline; the line still comes and the slot frees.
    @Test func shadow_uncooperative_engine_times_out() async {
        let logs = LockedList<String>()
        let local = AbandonOnlyLocal()
        let shadow = LocalSTTShadow(path: "conversation", engine: local, mic: { "builtin" }, log: { logs.append($0) }, rest: 0)
        shadow.finish(shadow.begin(index: 0, pcm16k: Self.voiced16k()), cloudText: "a b", cloudMs: 5, provider: "groq")
        let first = await Self.waitUntil(timeoutSeconds: 5) { logs.count == 1 }
        shadow.finish(shadow.begin(index: 1, pcm16k: Self.voiced16k()), cloudText: "c d", cloudMs: 5, provider: "groq")
        let second = await Self.waitUntil(timeoutSeconds: 5) { logs.count == 2 }
        let ok = first && second && logs.all.allSatisfy { $0.hasSuffix("result=local_timeout") } && local.abandons >= 1
        print("P \(ok ? "GREEN" : "RED") shadow_uncooperative_engine_times_out=\(ok ? 1 : 0) lines=\(logs.count) abandons=\(local.abandons)")
        #expect(ok)
    }

    /// Dictation releases its helper when the shadow goes away (no explicit end()).
    @Test func shadow_released_when_dropped() async {
        let releases = LockedList<Int>(), logs = LockedList<String>()
        do {
            let shadow = LocalSTTShadow(path: "dictation", engine: FakeShadowLocal(.text("x y")), release: { releases.append(1) },
                                        mic: { "builtin" }, log: { logs.append($0) })
            shadow.finish(shadow.begin(index: 0, pcm16k: Self.voiced16k()), cloudText: "x y", cloudMs: 5, provider: "groq")
            _ = await Self.waitUntil(timeoutSeconds: 3) { logs.count == 1 }
        }
        let ok = await Self.waitUntil(timeoutSeconds: 3) { releases.count >= 1 }
        print("P \(ok ? "GREEN" : "RED") shadow_released_when_dropped=\(ok ? 1 : 0) releases=\(releases.count)")
        #expect(ok)
    }
}

/// Never honours cancellation; only `abandon()` ends a request (a helper that hung past its deadline).
private final class AbandonOnlyLocal: LocalChunkSTT, @unchecked Sendable {
    let modelID = "abandon-only"
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<String, Error>] = []
    private var _abandons = 0
    var abandons: Int { lock.withLock { _abandons } }
    func transcribe(pcm16k: [Int16]) async throws -> String {
        try await withCheckedThrowingContinuation { c in lock.withLock { waiting.append(c) } }
    }
    func abandon() {
        let all = lock.withLock { _abandons += 1; defer { waiting.removeAll() }; return waiting }
        all.forEach { $0.resume(throwing: LocalSTTError.exited) }
    }
}
