// Latency harness for gate G6 and the A3 cleanup-model choice. Prints only
// counts and milliseconds — never transcript text, never the key.
//   DictateBench stt-groq     <fixture.wav> <runs>   time batch Groq transcription
//   DictateBench cleanup      <model> <runs>         time one cloud cleanup completion
//   DictateBench cleanup-local <model> <runs>        time one local (Ollama) cleanup
//   DictateBench eval         groq|local <model>    G7 quality: 11 cases, prints PASS/FAIL + misses
//   DictateBench eval-incremental groq <model>     Incremental quality: 12 cases
import DictateAppKit
import DictateCore
import Foundation

let prompt = Vocabulary.buildPrompt()
func environmentKey(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw TranscriptionError.missingKey
    }
    return value
}

func requireKey(_ name: String) {
    guard (try? environmentKey(name)) != nil else {
        print("missing \(name) — run via tools/bench.sh")
        exit(2)
    }
}

func makeLocalCleaner(model: String) -> TranscriptCleaner {
    var cleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: 30), endpoint: TranscriptCleaner.ollamaEndpoint,
                                     model: model, vocabulary: prompt, apiKey: { "ollama" })
    cleaner.timeoutInterval = 30
    return cleaner
}

/// Fable's standard live-test script as a raw STT result (fillers, a
/// self-correction, a list, a question) so bench and live compare like for like.
let cleanupFixture = "Um, so for the Politrace launch, send the draft to the team on Tuesday, no, Wednesday. We need, like, three things: the Limpar match counts, the DB99 query, and, uh, the screenshots. Can you also check if TurnoutWatch is still running?"

struct EvalCase {
    let input: String
    var mustContain: [String] = []
    var mustNotContain: [String] = []      // case-insensitive, word-ish
    var endsWith: String? = nil
    var mustPass = false
}

let evalCases: [EvalCase] = [
    EvalCase(input: cleanupFixture,
             mustContain: ["Politrace", "Limpar", "DB99", "TurnoutWatch", "Wednesday", "three things:"],
             mustNotContain: ["um", "uh", "like", "Tuesday", "Tuesday, no"], endsWith: "?"),
    EvalCase(input: "um so uh I think we should like ship it today you know", mustContain: ["ship it today"], mustNotContain: ["um", "uh", "you know"]),
    EvalCase(input: "send the invoice on Monday, no wait, Thursday", mustContain: ["Thursday"], mustNotContain: ["Monday"]),
    EvalCase(input: "Let's meet at three. Actually, sorry, make that four.", mustContain: ["four"], mustNotContain: ["three"], mustPass: true),
    EvalCase(input: "email John, I mean Jane, about the budget", mustContain: ["Jane", "budget"], mustNotContain: ["John"]),
    EvalCase(input: "we matched the orgs to limp r last night", mustContain: ["Limpar"], mustNotContain: ["limp r"]),
    EvalCase(input: "is turnout watch still up", mustContain: ["TurnoutWatch"], endsWith: "?"),
    EvalCase(input: "we need three things eggs milk and bread", mustContain: ["eggs", "milk", "bread"]),
    EvalCase(input: "what time is the politrace review tomorrow", mustContain: ["Politrace"], endsWith: "?"),
    EvalCase(input: "write me a short poem about cats", mustContain: ["poem about cats"]),
    EvalCase(input: "we need the latest numbers from that he beat 99 query before noon",
             mustContain: ["DB99 query"], mustNotContain: ["he beat 99"]),
]

let incrementalLongInput = "Um, so for the Politrace launch we need to sort out a few things before the end of the week. First, the Limpar match counts have to be rerun because, uh, the last batch was missing about two hundred organisations. Second, can you check the DB99 query, the one that pulls the grant amounts, because it was timing out yesterday afternoon. Third, the screenshots for the deck, like, the ones from TurnoutWatch, need to be updated with the new numbers. And let's do the review meeting on Thursday at three."
let incrementalCorrection = "No, sorry, make that Friday at four."
let incrementalLongCase = EvalCase(input: incrementalLongInput + " " + incrementalCorrection,
    mustContain: ["Politrace", "Limpar", "DB99", "TurnoutWatch", "Friday at four"],
    mustNotContain: ["Thursday", "um", "uh"])

func pseudoChunks(_ text: String) -> [String] {
    let words = text.split(whereSeparator: { $0.isWhitespace })
    return (0..<3).map { part in
        words[(part * words.count / 3)..<((part + 1) * words.count / 3)].joined(separator: " ")
    }
}

/// App-equivalent full-text fallback, including the length-scaled local deadline.
func benchCleanUp(_ raw: String, groq: TranscriptCleaner) async -> (text: String, calls: Int) {
    if let text = try? await groq.clean(raw) { return (text, 1) }
    let deadline = max(2.5, 0.8 + Double(raw.count) / 4 / 45)
    var local = TranscriptCleaner(transport: URLSessionTransport(timeout: deadline),
        endpoint: TranscriptCleaner.ollamaEndpoint, model: TranscriptCleaner.localModel,
        vocabulary: groq.vocabulary, apiKey: { "ollama" })
    local.reloadVocabularyFromHints = groq.reloadVocabularyFromHints
    local.timeoutInterval = deadline
    return ((try? await local.clean(raw)) ?? raw, 2)
}

/// The expected paste for Fable's standard live-test script.
let expectedScript = "So for the Politrace launch, send the draft to the team on Wednesday. We need three things: the Limpar match counts, the DB99 query, and the screenshots. Can you also check if TurnoutWatch is still running?"

func words(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
}

/// Names spelled exactly (of 4) and expected-word recall, for STT engines.
func scriptScore(_ out: String) -> String {
    let names = ["Politrace", "Limpar", "DB99", "TurnoutWatch"].filter { out.contains($0) }
    var pool = words(out)
    var hit = 0
    for w in words(expectedScript) { if let i = pool.firstIndex(of: w) { pool.remove(at: i); hit += 1 } }
    let missing = ["Politrace", "Limpar", "DB99", "TurnoutWatch"].filter { !out.contains($0) }
    return "names=\(names.count)/4 word_recall=\(hit)/\(words(expectedScript).count) missing_names=\(missing)"
}

func score(_ c: EvalCase, _ out: String) -> [String] {
    var misses: [String] = []
    let lower = out.lowercased()
    for need in c.mustContain where !out.contains(need) { misses.append("missing \"\(need)\"") }
    for bad in c.mustNotContain {
        let pattern = "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: bad.lowercased()) + "($|[^a-z])"
        if lower.range(of: pattern, options: .regularExpression) != nil { misses.append("contains \"\(bad)\"") }
    }
    if let end = c.endsWith, !out.hasSuffix(end) { misses.append("does not end with \"\(end)\"") }
    if Double(out.count) > 1.5 * Double(c.input.count) { misses.append("added content (\(out.count) chars vs \(c.input.count) in)") }
    return misses
}

func samples(fromWAV url: URL) throws -> [Int16] {
    let data = try Data(contentsOf: url)
    var offset = 12
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
        if id == "data" {
            let body = data[(offset + 8)..<min(data.count, offset + 8 + size)]
            return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map {
                Int16(bitPattern: UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8)
            }
        }
        offset += 8 + size + (size & 1)
    }
    throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "no data chunk"])
}

func ms(since start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

func p50(_ values: [Int]) -> Int {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

/// Independent, literal transcription of the normal-dictation spec pseudocode.
/// This reference never calls WisprLevel or PillBars.
struct SpecPill {
    var noiseFloorDb = 0.0
    var pendingLevels: [Double] = []
    var target = 0.0
    var smoothed = 0.0

    mutating func onMicrophoneChunk(_ samples: [Float]) {
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = sqrt(sum / Double(samples.count))
        let db = 20 * log10(rms + 1e-10)
        if db < noiseFloorDb { noiseFloorDb = max(-60, db) }
        pendingLevels.append(min(1, max(0, (db - noiseFloorDb) / 20)))
    }

    mutating func every150Milliseconds() {
        if pendingLevels.isEmpty { return }
        target = pendingLevels.reduce(0, +) / Double(pendingLevels.count)
        pendingLevels.removeAll()
    }

    mutating func onAnimationFrame() {
        smoothed = floor(100 * (0.85 * smoothed + 0.15 * target)) / 100
    }

    func heightsAtPresentationTime(_ now: Double) -> [Double] {
        let keyframes = [(0.0, 1.0), (0.2, 1.2), (0.4, 1.5), (0.8, 1.1), (0.9, 1.3), (1.0, 1.0)]
        return (0..<10).map { index in
            let profile = max(0, 1 - pow(abs(4.5 - Double(index)), 2) / 48)
            let signedIndex = index < 5 ? index : index - 10
            let elapsed = now - 0.1 * Double(signedIndex)
            var multiplier = 1.0
            if elapsed >= 0 {
                let phase = elapsed - floor(elapsed)
                for k in 1..<keyframes.count {
                    let (t0, v0) = keyframes[k - 1], (t1, v1) = keyframes[k]
                    if phase <= t1 {
                        let progress = (phase - t0) / (t1 - t0)
                        // Invert x with Newton iterations; Core uses bisection.
                        var parameter = progress
                        for _ in 0..<12 {
                            let x = 1.26 * parameter - 0.78 * parameter * parameter + 0.52 * pow(parameter, 3)
                            let derivative = 1.26 - 1.56 * parameter + 1.56 * parameter * parameter
                            parameter = min(1, max(0, parameter - (x - progress) / derivative))
                        }
                        let eased = 3 * parameter * parameter - 2 * pow(parameter, 3)
                        multiplier = v0 + (v1 - v0) * eased
                        break
                    }
                }
            }
            return 2 * max(1, 5 * smoothed) * profile * multiplier
        }
    }
}

struct PillMatchDiff {
    var maxAbsolute = 0.0
    var maxRelative = 0.0
    mutating func include(actual: [Double], wispr: [Double]) {
        guard actual.count == wispr.count else { maxRelative = .infinity; return }
        for (a, w) in zip(actual, wispr) {
            guard a.isFinite, w.isFinite, w > 0 else { maxRelative = .infinity; continue }
            let difference = abs(a - w)
            maxAbsolute = max(maxAbsolute, difference)
            maxRelative = max(maxRelative, difference / w)
        }
    }
    var passes: Bool { maxRelative <= 0.10 }
}

/// Model a 1024-frame 16 kHz tap converted to 1536 floats at 24 kHz.
/// Chunk arrivals, 150 ms delivery and 60 fps presentation are separate clocks.
func replayPill(_ pcm: [Float]) -> (frames: [[Double]], diff: PillMatchDiff, speech: [Int]) {
    let chunkSize = 1536
    let duration = Double(pcm.count) / 24_000
    var meter = WisprLevel(), bars = PillBars(), reference = SpecPill()
    var cursor = 0, batchIndex = 1
    let firstArrival = Double(min(chunkSize, pcm.count)) / 24_000
    var frames: [[Double]] = [], speech: [Int] = []
    var diff = PillMatchDiff()
    for frame in 0...Int(ceil((duration + 0.150) * 60)) {
        let time = Double(frame) / 60
        while true {
            let chunkEnd = min(pcm.count, cursor + chunkSize)
            let arrival = cursor < pcm.count ? Double(chunkEnd) / 24_000 : Double.infinity
            let batchTime = firstArrival + Double(batchIndex) * 0.150
            let eventTime = min(arrival, batchTime)
            if eventTime > time + 1e-12 { break }
            if arrival <= batchTime {
                let chunk = Array(pcm[cursor..<chunkEnd])
                meter.append(db: WisprLevel.db(samples: chunk), at: arrival)
                reference.onMicrophoneChunk(chunk)
                cursor = chunkEnd
            } else {
                if let mean = meter.batch(at: batchTime) { bars.push(level: mean) }
                reference.every150Milliseconds()
                batchIndex += 1
            }
        }
        bars.tick()
        reference.onAnimationFrame()
        let heights = bars.heights(at: time)
        diff.include(actual: heights, wispr: reference.heightsAtPresentationTime(time))
        frames.append(heights)
        let start = frame * 400, end = min(pcm.count, start + 400)
        if start < end, WisprLevel.db(samples: Array(pcm[start..<end])) > -40 { speech.append(frame) }
    }
    return (frames, diff, speech)
}

let args = CommandLine.arguments
if args.count >= 2, args[1] == "pill-render" {
    guard args.count == 6, ["0", "1"].contains(args[4]) else {
        print("usage: DictateBench pill-render <held|error|raw> <reason> <hasText 0|1> <out.png>")
        exit(2)
    }
    let kind: PillOutcome.Kind
    switch args[2] {
    case "held": kind = .held(args[3])
    case "error": kind = .error(args[3])
    case "raw": kind = .rawPasted(args[3])
    default: print("pill-render kind must be held, error, or raw"); exit(2)
    }
    let outcome = PillOutcome(kind, hasText: args[4] == "1")
    try PillPanel.renderOutcomePNG(label: outcome.label ?? "error", held: outcome.showsPasteAffordance,
                                   to: URL(fileURLWithPath: args[5]))
    exit(0)
}
if args.count >= 3, args[1] == "pill-match" {
    // Literal controls prove that the comparison gate accepts good and rejects bad.
    var good = PillMatchDiff(), bad = PillMatchDiff()
    good.include(actual: [2.0], wispr: [2.0])
    bad.include(actual: [2.5], wispr: [2.0])
    print("PILLMATCH_CONTROL actual=[2.0] wispr=[2.0] GREEN=\(good.passes ? "PASS" : "FAIL") actual=[2.5] wispr=[2.0] RED=\(bad.passes ? "PASS" : "FAIL")")
    guard good.passes, !bad.passes else { exit(1) }
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2])).map { Float($0) / 32_768 }
    guard !pcm.isEmpty else { print("PILLMATCH error=empty_fixture"); exit(1) }
    let replay = replayPill(pcm)
    print(String(format: "PILLMATCH frames=%d max_abs_diff_pt=%.12g max_rel_diff=%.12g%%", replay.frames.count,
                 replay.diff.maxAbsolute, replay.diff.maxRelative * 100))
    guard !replay.speech.isEmpty else { print("PILLMATCH error=no_speech"); exit(1) }
    let middle = replay.speech[replay.speech.count / 2]
    for index in [middle - 6, middle, middle + 6] where replay.frames.indices.contains(index) {
        print(String(format: "frame t=%.3fs heights pt: %@", Double(index) / 60,
                     replay.frames[index].map { String(format: "%.1f", $0) }.joined(separator: " ")))
    }
    exit(replay.diff.passes ? 0 : 1)
}
// Keep the G10 QA command; its current-model path uses the same replay as G11.
if args.count >= 3, args[1] == "levels" {
    let old = args.count > 3 && args[3] == "old"
    let gainDB = Float(args.count > 4 ? args[4] : "0") ?? 0
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2])).map { Float($0) / 32_768 * pow(10, gainDB / 20) }
    let replay = replayPill(pcm)
    var oldSmoothed = 0.0, oldPhase = 0.0
    var frames = replay.frames
    if old {
        for frame in frames.indices {
            let start = frame * 400, end = min(pcm.count, start + 400)
            let level = start < end ? Double(AudioLevel.normalized(rms: AudioLevel.rms(Array(pcm[start..<end])))) : 0
            oldSmoothed += (level - oldSmoothed) * (level > oldSmoothed ? 0.48 : 0.124)
            oldPhase += 1.0 / 60
            frames[frame] = (0..<10).map { i in
                let v = 0.55 + 0.45 * (0.5 + 0.5 * sin(oldPhase * (2.1 + Double((i * 7) % 5) * 0.37) + Double((i * 3) % 7) * 0.9))
                let c = 1 - abs(Double(i) - 4.5) / 10 * 0.6
                return 2 + 14 * oldSmoothed * v * c
            }
        }
    }
    guard !replay.speech.isEmpty else { print("LEVELS error=no_speech"); exit(1) }
    let top3 = replay.speech.map { frames[$0].sorted(by: >).prefix(3).reduce(0, +) / 3 / (old ? 16 : PillBars.peakHeight) * 100 }
    let above = replay.speech.map { frames[$0].filter { $0 > 2.5 }.count }
    let t = top3.sorted(), a = above.sorted()
    let pass = zip(top3, above).filter { $0 >= 70 && $1 >= 7 }.count
    let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
    print(String(format: "LEVELS %@ gain=%+.0fdB fixture_peak=%.1fdBFS speech_frames=%d median_top3=%.0f%% median_bars_above_idle=%d pass_rate=%.0f%%",
                 old ? "OLD" : "NEW", gainDB, 20 * log10(Double(peak)), top3.count, t[t.count / 2], a[a.count / 2], Double(pass) / Double(top3.count) * 100))
    exit(0)
}
// Fail before reading fixtures/stdin or contacting any provider when its key is absent.
if args.count >= 2 {
    switch args[1] {
    case "score-text": requireKey("GROQ_API_KEY")
    case "stt-groq" where args.count >= 4, "stt-groq-chunked" where args.count >= 4: requireKey("GROQ_API_KEY")
    case "cleanup" where args.count >= 4:
        requireKey("GROQ_API_KEY")
    case "eval-incremental" where args.count >= 4:
        guard args[2] == "groq" else { print("eval-incremental backend must be groq"); exit(2) }
        requireKey("GROQ_API_KEY")
    case "eval" where args.count >= 4:
        guard ["groq", "local"].contains(args[2]) else {
            print("eval backend must be groq or local")
            exit(2)
        }
        if args[2] == "groq" { requireKey("GROQ_API_KEY") }
    default: break
    }
}
// score-text: clean stdin (an STT transcript) with local llama and Groq qwen, score vs the script.
if args.count >= 2, args[1] == "score-text" {
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    print("RAW \(scriptScore(raw))")
    let local = makeLocalCleaner(model: TranscriptCleaner.localModel)
    if let out = try? await local.cleanWithStats(raw).text { print("LOCAL-llama3.2:3b \(scriptScore(out))") }
    var groq = TranscriptCleaner(transport: URLSessionTransport(timeout: 10), endpoint: TranscriptCleaner.groqEndpoint, model: "qwen/qwen3.8-27b", vocabulary: prompt, apiKey: { try environmentKey("GROQ_API_KEY") })
    groq.reasoningEffort = "none"
    if let out = try? await groq.cleanWithStats(raw).text { print("GROQ-qwen3.8-27b \(scriptScore(out))") }
    exit(0)
}
guard args.count >= 4 else {
    print("usage: DictateBench pill-render <held|error|raw> <reason> <hasText 0|1> <out.png> | pill-match <wav> | stt-groq|stt-groq-chunked <wav> <runs> | cleanup <model> <runs>")
    print("stt-groq-chunked: BENCH_V3=0 uses old 2/3 s limits without fillers; default/BENCH_V3=1 uses V3 3/4 s limits with fillers (synthetic WAV fixtures only)")
    exit(2)
}
let runs = Int(args[3]) ?? 5
guard runs > 0 else { print("runs must be positive"); exit(2) }
let endToEnd = args[1] == "stt-groq-chunked" && ProcessInfo.processInfo.environment["BENCH_E2E"] == "1"
var results: [Int] = []
var lastText: String?

switch args[1] {
case "stt-groq-chunked":
    let useV3 = ProcessInfo.processInfo.environment["BENCH_V3"] != "0"
    let firstMinimumSeconds = useV3 ? 3.0 : 2.0
    let firstMaximumSeconds = useV3 ? 4.0 : 3.0
    print("variant=\(useV3 ? "v3" : "old") first_min_s=\(firstMinimumSeconds) first_max_s=\(firstMaximumSeconds) lead_in=\(useV3 ? "on" : "off")")
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2]))
    let transport = URLSessionTransport(timeout: 30)
    let tailValue = ProcessInfo.processInfo.environment["BENCH_TAIL_MS"] ?? "1500"
    guard let tailMs = Int(tailValue), (0...60_000).contains(tailMs) else {
        print("BENCH_TAIL_MS must be an integer from 0 to 60000")
        exit(2)
    }
    let cleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: 1.5),
                                    endpoint: TranscriptCleaner.groqEndpoint, model: TranscriptCleaner.defaultModel,
                                    vocabulary: prompt, apiKey: { try environmentKey("GROQ_API_KEY") })
    let useIncremental = endToEnd && ProcessInfo.processInfo.environment["BENCH_INCREMENTAL"] != "0"
    for run in 1...runs {
        var chunker = PauseChunker(firstMinimumSeconds: firstMinimumSeconds, firstMaximumSeconds: firstMaximumSeconds)
        let incremental = useIncremental ? IncrementalCleaner(cleaner: cleaner) : nil
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { try environmentKey("GROQ_API_KEY") }, prompt: prompt,
                                           fillerLeadIn: useV3, firstMinimumSeconds: firstMinimumSeconds,
                                           firstMaximumSeconds: firstMaximumSeconds,
                                           onChunkText: { index, text in incremental?.append(index: index, text: text) })
        let started = DispatchTime.now().uptimeNanoseconds
        var fed = 0
        func feed(_ samples: [Int16]) async throws {
            fed += samples.count
            let deadline = started + UInt64(Double(fed) / 24_000 * 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
            for chunk in chunker.append(samples) { engine.submit(chunk) }
        }
        for offset in stride(from: 0, to: pcm.count, by: 2_400) {
            try await feed(Array(pcm[offset..<min(pcm.count, offset + 2_400)]))
        }
        let tailSamples = tailMs * 24
        for offset in stride(from: 0, to: tailSamples, by: 2_400) {
            try await feed([Int16](repeating: 0, count: min(2_400, tailSamples - offset)))
        }
        let finish = DispatchTime.now()
        for chunk in chunker.finish() where chunk.samples.count >= 7_200 { engine.submit(chunk) }
        let joined = await engine.finish(at: finish)
        let elapsed = ms(since: finish)
        if joined.failedCount == 0, !joined.text.isEmpty {
            if endToEnd {
                var cleaned = joined.text
                var mode = incremental?.needsFallback == true ? "incremental_fallback" : "single"
                var calls = incremental?.callCount ?? 0
                var reason = "-"
                if TranscriptCleaner.shouldClean(joined.text) {
                    let output = await incremental?.finish(totalChunks: joined.chunks)
                    mode = output?.mode ?? "single"
                    reason = output?.fallbackReason ?? "-"
                    calls = output?.calls ?? 0
                    if let text = output?.text { cleaned = text }
                    else {
                        let fallback = await benchCleanUp(joined.text, groq: cleaner)
                        cleaned = fallback.text
                        calls += fallback.calls
                    }
                }
                incremental?.cancel()
                let pasteMs = ms(since: finish)
                results.append(pasteMs)
                lastText = cleaned
                print("run \(run) finish_to_final_ms=\(elapsed) finish_to_paste_ms=\(pasteMs) chunks=\(joined.chunks) chars=\(cleaned.count) cleanup_mode=\(mode) cleanup_calls=\(calls) fallback_reason=\(reason)")
            } else {
                results.append(elapsed)
                lastText = joined.text
                print("run \(run) finish_to_final_ms=\(elapsed) chunks=\(joined.chunks) chars=\(joined.text.count) rpm_remaining=\(joined.rateLimits?.rpmRemaining ?? "-") rpd_remaining=\(joined.rateLimits?.rpdRemaining ?? "-")")
            }
        } else {
            incremental?.cancel()
            let mode = incremental == nil ? "single" : "incremental_fallback"
            print("run \(run) chunk_fallback=\(joined.failedCount) chunks=\(joined.chunks)" + (endToEnd ? " cleanup_mode=\(mode) cleanup_calls=\(incremental?.callCount ?? 0)" : ""))
        }
    }
case "stt-apple":
    // F9 / G9: Apple on-device SpeechAnalyzer, the app's own AppleTranscriber,
    // fed at real-time pace in 100 ms chunks plus a 300 ms tap tail.
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2]))
    await AppleTranscriber.ensureAssets()
    for run in 1...runs {
        let engine = AppleTranscriber()
        try await engine.start()
        for start in stride(from: 0, to: pcm.count, by: 2_400) {
            engine.append(Array(pcm[start..<min(pcm.count, start + 2_400)]))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        for _ in 0..<3 {
            engine.append([Int16](repeating: 0, count: 2_400))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let finish = DispatchTime.now()
        do {
            let text = try await engine.finish()
            let elapsed = ms(since: finish)
            results.append(elapsed)
            lastText = text
            print("run \(run) finish_to_final_ms=\(elapsed) chars=\(text.count)")
        } catch {
            print("run \(run) error=\(error)")
        }
    }
case "stt-groq":
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2]))
    let wav = WAVEncoder.encode(samples: pcm, sampleRate: 24_000)
    var client = TranscriptionClient(transport: URLSessionTransport(timeout: 60), apiKey: { try environmentKey("GROQ_API_KEY") })
    client.modelName = ProcessInfo.processInfo.environment["GROQ_STT_MODEL"] ?? TranscriptionClient.model
    _ = try? await client.transcribe(wav: WAVEncoder.encode(samples: [Int16](repeating: 0, count: 2_400), sampleRate: 24_000), prompt: "")   // warm TLS
    for run in 1...runs {
        let start = DispatchTime.now()
        do {
            // GROQ_PROMPT=1: pass the vocabulary as the whisper prompt (name-recall comparison).
            let text = try await client.transcribe(wav: wav, prompt: ProcessInfo.processInfo.environment["GROQ_PROMPT"] == "1" ? prompt : "")
            let elapsed = ms(since: start)
            results.append(elapsed)
            lastText = text
            print("run \(run) finish_to_final_ms=\(elapsed) bytes=\(wav.count) chars=\(text.count)")
        } catch {
            print("run \(run) error=\(error)")
        }
    }
case "cleanup":
    var cleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: 10), endpoint: TranscriptCleaner.groqEndpoint,
                                    model: args[2], vocabulary: prompt, apiKey: { try environmentKey("GROQ_API_KEY") })
    cleaner.reasoningEffort = ProcessInfo.processInfo.environment["BENCH_REASONING"] ?? "none"
    // One unmeasured call warms the keep-alive connection, as the app does during recording.
    _ = try? await cleaner.clean(cleanupFixture)
    for run in 1...runs {
        let start = DispatchTime.now()
        do {
            let (text, stats) = try await cleaner.cleanWithStats(cleanupFixture)
            let elapsed = ms(since: start)
            results.append(elapsed)
            print("run \(run) model=\(args[2]) cleanup_ms=\(elapsed) first_byte_ms=\(stats.firstByteMs ?? -1) words_in=\(cleanupFixture.split(separator: " ").count) chars_out=\(text.count)")
        } catch {
            print("run \(run) model=\(args[2]) error=\(error)")
        }
    }
case "cleanup-local":
    let cleaner = makeLocalCleaner(model: args[2])
    await cleaner.warmUp()
    for run in 1...runs {
        let start = DispatchTime.now()
        do {
            let (text, stats) = try await cleaner.cleanWithStats(cleanupFixture)
            let elapsed = ms(since: start)
            results.append(elapsed)
            let toks = stats.completionTokens ?? 0
            print("run \(run) model=\(args[2]) cleanup_ms=\(elapsed) tokens=\(toks) tok_per_s=\(elapsed > 0 ? toks * 1000 / elapsed : 0) words_in=\(cleanupFixture.split(separator: " ").count) chars_out=\(text.count)")
        } catch {
            print("run \(run) model=\(args[2]) error=\(error)")
        }
    }
case "eval", "eval-incremental":
    let isIncremental = args[1] == "eval-incremental"
    let model = args[3]
    var groqCleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: 10), endpoint: TranscriptCleaner.groqEndpoint, model: model, vocabulary: prompt, apiKey: { try environmentKey("GROQ_API_KEY") })
    groqCleaner.reasoningEffort = ProcessInfo.processInfo.environment["BENCH_REASONING"] ?? "none"
    let cleaner: TranscriptCleaner = args[2] == "local"
        ? makeLocalCleaner(model: model)
        : groqCleaner
    await cleaner.warmUp()
    var passed = 0
    let cases = isIncremental ? evalCases + [incrementalLongCase] : evalCases
    for (i, c) in cases.enumerated() {
        if i > 0 { try await Task.sleep(nanoseconds: 8_000_000_000) }
        do {
            let out: String
            if isIncremental {
                let incremental = IncrementalCleaner(cleaner: cleaner)
                let chunks = i == evalCases.count
                    ? pseudoChunks(incrementalLongInput) + [incrementalCorrection] : pseudoChunks(c.input)
                for (index, text) in chunks.enumerated() {
                    incremental.append(index: index, text: text)
                    await incremental.waitForPending()
                }
                let output = await incremental.finish(totalChunks: chunks.count)
                if let text = output.text { out = text }
                else { out = try await cleaner.clean(c.input) }
            } else { out = try await cleaner.cleanWithStats(c.input).text }
            let misses = score(c, out)
            if misses.isEmpty { passed += 1 }
            print("case \(i + 1) \(misses.isEmpty ? "PASS" : "FAIL") \(misses.joined(separator: "; "))")
            if c.mustPass, !misses.isEmpty { print("MUSTPASS FAIL case \(i + 1)") }
            if !misses.isEmpty, ProcessInfo.processInfo.environment["EVAL_SHOW"] == "1" { print("   out: \(out)") }
        } catch {
            print("case \(i + 1) ERROR \(error)")
            if c.mustPass { print("MUSTPASS FAIL case \(i + 1)") }
        }
    }
    print("\(isIncremental ? "EVAL-INCREMENTAL" : "EVAL") \(args[2]) \(model) \(passed)/\(cases.count)")
    exit(0)
default:
    print("unknown command \(args[1])")
    exit(2)
}
if !results.isEmpty {
    if let text = lastText, ProcessInfo.processInfo.environment["SHOW_TEXT"] == "1" { print("TEXT \(text)") }
    if let raw = lastText, ProcessInfo.processInfo.environment["BENCH_SCORE"] == "1" {
        // Score STT on the standard script AFTER the local cleanup pass.
        let cleaned = (try? await makeLocalCleaner(model: TranscriptCleaner.localModel).cleanWithStats(raw).text) ?? raw
        print("SCORE \(scriptScore(cleaned))")
    }
    let pasteMetric = endToEnd ? " finish_to_paste_ms=\(p50(results))" : ""
    print("RESULT \(args[1]) \(args[2].split(separator: "/").last ?? "") n=\(results.count) p50_ms=\(p50(results))\(pasteMetric) min_ms=\(results.min()!) max_ms=\(results.max()!)")
}
if endToEnd, results.count != runs { exit(1) }
