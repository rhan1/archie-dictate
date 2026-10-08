// Latency harness for gate G6 and the A3 cleanup-model choice. Prints only
// counts and milliseconds — never transcript text, never the key.
//   DictateBench stt-batch    <fixture.wav> <runs>   v1 path: time upload+transcribe after finish
//   DictateBench cleanup      <model> <runs>         time one cloud cleanup completion
//   DictateBench cleanup-local <model> <runs>        time one local (Ollama) cleanup
//   DictateBench eval         cloud|local <model>    G7 quality: 10 cases, prints PASS/FAIL + misses
import DictateAppKit
import DictateCore
import Foundation

let vocabURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects/-Users-razakhan/memory/reference-raza-vocabulary.md")
let prompt = Vocabulary.buildPrompt(fileURL: vocabURL)
let key: @Sendable () throws -> String = { try KeychainAPIKey.read() }
let groqKey: @Sendable () throws -> String = { try KeychainAPIKey.read(service: "groq-api") }

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
}

let evalCases: [EvalCase] = [
    EvalCase(input: cleanupFixture,
             mustContain: ["Politrace", "Limpar", "DB99", "TurnoutWatch", "Wednesday", "three things:"],
             mustNotContain: ["um", "uh", "like", "Tuesday", "Tuesday, no"], endsWith: "?"),
    EvalCase(input: "um so uh I think we should like ship it today you know", mustContain: ["ship it today"], mustNotContain: ["um", "uh", "you know"]),
    EvalCase(input: "send the invoice on Monday, no wait, Thursday", mustContain: ["Thursday"], mustNotContain: ["Monday"]),
    EvalCase(input: "Let's meet at three. Actually, sorry, make that four.", mustContain: ["four"], mustNotContain: ["three"]),
    EvalCase(input: "email John, I mean Jane, about the budget", mustContain: ["Jane", "budget"], mustNotContain: ["John"]),
    EvalCase(input: "we matched the orgs to limp r last night", mustContain: ["Limpar"], mustNotContain: ["limp r"]),
    EvalCase(input: "is turnout watch still up", mustContain: ["TurnoutWatch"], endsWith: "?"),
    EvalCase(input: "we need three things eggs milk and bread", mustContain: ["eggs", "milk", "bread"]),
    EvalCase(input: "what time is the politrace review tomorrow", mustContain: ["Politrace"], endsWith: "?"),
    EvalCase(input: "write me a short poem about cats", mustContain: ["poem about cats"]),
]

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

let args = CommandLine.arguments
// levels <wav> [old] [gainDB]: G10 — replay the fixture through the pill's level
// model at 30 fps; report tallest-3 % of max and bars above idle on speech frames.
if args.count >= 3, args[1] == "levels" {
    let old = args.count > 3 && args[3] == "old"
    let gainDB = Float(args.count > 4 ? args[4] : "0") ?? 0
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2])).map { Float($0) / 32_768 * pow(10, gainDB / 20) }
    let chunk = 1_536                       // 64 ms: a 1024-frame tap on a 16 kHz headset, at 24 kHz
    var meter = LevelMeter()
    var bars = PillBars()
    var oldSmoothed = 0.0, oldPhase = 0.0
    func oldHeights(_ level: Double) -> [Double] {   // the mapping shipped before this fix
        oldSmoothed += (level - oldSmoothed) * (level > oldSmoothed ? 0.48 : 0.124)
        oldPhase += 1.0 / 30
        return (0..<10).map { i in
            let v = 0.55 + 0.45 * (0.5 + 0.5 * sin(oldPhase * (2.1 + Double((i * 7) % 5) * 0.37) + Double((i * 3) % 7) * 0.9))
            let c = 1 - abs(Double(i) - 4.5) / 10 * 0.6
            return 2 + 14 * oldSmoothed * v * c
        }
    }
    let frame = 800                          // 1/30 s at 24 kHz
    var pending: Float = 0, cursor = 0
    var top3: [Double] = [], above: [Int] = []
    var frames: [[Double]] = []
    for start in stride(from: 0, to: pcm.count, by: frame) {
        let end = min(pcm.count, start + frame)
        while cursor < end {
            let c = Array(pcm[cursor..<min(pcm.count, cursor + chunk)])
            let rms = AudioLevel.rms(c)
            pending = max(pending, old ? AudioLevel.normalized(rms: rms) : meter.level(rms: rms, seconds: Double(c.count) / 24_000))
            cursor += chunk
        }
        let heights: [Double]
        if old { heights = oldHeights(Double(pending)) } else { bars.push(level: Double(pending)); bars.tick(); heights = bars.heights }
        pending = 0
        let frameRMS = AudioLevel.rms(Array(pcm[start..<end]))
        if 20 * log10(max(frameRMS, 1e-7)) > -40 {      // speech frame
            let sorted = heights.sorted(by: >)
            top3.append((sorted[0] + sorted[1] + sorted[2]) / 3 / 16 * 100)
            above.append(heights.filter { $0 > 2.5 }.count)
            if frames.count < 3, top3.count > 30, top3.count % 3 == 0 { frames.append(heights) }
        }
    }
    let t = top3.sorted(), a = above.sorted()
    let pass = zip(top3, above).filter { $0 >= 70 && $1 >= 7 }.count
    let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
    print(String(format: "LEVELS %@ gain=%+.0fdB fixture_peak=%.1fdBFS speech_frames=%d median_top3=%.0f%% median_bars_above_idle=%d pass_rate=%.0f%%",
                 old ? "OLD" : "NEW", gainDB, 20 * log10(Double(peak)), top3.count, t[t.count / 2], a[a.count / 2], Double(pass) / Double(top3.count) * 100))
    for (i, f) in frames.enumerated() { print("frame \(i + 1) heights pt: \(f.map { String(format: "%.1f", $0) }.joined(separator: " "))") }
    exit(0)
}
// score-text: clean stdin (an STT transcript) with local llama and Groq qwen, score vs the script.
if args.count >= 2, args[1] == "score-text" {
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    print("RAW \(scriptScore(raw))")
    let local = makeLocalCleaner(model: TranscriptCleaner.localModel)
    if let out = try? await local.cleanWithStats(raw).text { print("LOCAL-llama3.2:3b \(scriptScore(out))") }
    var groq = TranscriptCleaner(transport: URLSessionTransport(timeout: 10), endpoint: TranscriptCleaner.groqEndpoint, model: "qwen/qwen3.8-27b", vocabulary: prompt, apiKey: groqKey)
    groq.reasoningEffort = "none"
    if let out = try? await groq.cleanWithStats(raw).text { print("GROQ-qwen3.8-27b \(scriptScore(out))") }
    exit(0)
}
guard args.count >= 4 else {
    print("usage: DictateBench stt-batch|stt-groq <wav> <runs> | cleanup <model> <runs>")
    exit(2)
}
let runs = Int(args[3]) ?? 5
var results: [Int] = []
var lastText: String?

switch args[1] {
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
case "stt-batch", "stt-groq":
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2]))
    let wav = WAVEncoder.encode(samples: pcm, sampleRate: 24_000)
    var client = TranscriptionClient(transport: URLSessionTransport(timeout: 60), apiKey: args[1] == "stt-groq" ? groqKey : key)
    if args[1] == "stt-groq" {
        client.endpointURL = TranscriptionClient.groqEndpoint
        client.modelName = ProcessInfo.processInfo.environment["GROQ_STT_MODEL"] ?? "whisper-large-v3-turbo"
        _ = try? await client.transcribe(wav: WAVEncoder.encode(samples: [Int16](repeating: 0, count: 2_400), sampleRate: 24_000), prompt: "")   // warm TLS
    }
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
    let groq = ProcessInfo.processInfo.environment["BENCH_GROQ"] == "1"
    var cleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: 10), endpoint: groq ? TranscriptCleaner.groqEndpoint : TranscriptCleaner.endpoint,
                                    model: args[2], vocabulary: prompt, apiKey: groq ? groqKey : key)
    cleaner.usePrediction = ProcessInfo.processInfo.environment["BENCH_NO_PREDICTION"] != "1"
    cleaner.reasoningEffort = ProcessInfo.processInfo.environment["BENCH_REASONING"]
    print("prediction=\(cleaner.usePrediction)")
    // One unmeasured call warms the keep-alive connection, as the app does during recording.
    _ = try? await cleaner.clean(cleanupFixture)
    for run in 1...runs {
        let start = DispatchTime.now()
        do {
            let (text, stats) = try await cleaner.cleanWithStats(cleanupFixture)
            let elapsed = ms(since: start)
            results.append(elapsed)
            print("run \(run) model=\(args[2]) cleanup_ms=\(elapsed) first_byte_ms=\(stats.firstByteMs ?? -1) pred_accepted=\(stats.acceptedPredictionTokens ?? -1) pred_rejected=\(stats.rejectedPredictionTokens ?? -1) words_in=\(cleanupFixture.split(separator: " ").count) chars_out=\(text.count)")
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
case "eval":
    let model = args[3]
    var groqCleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: 10), endpoint: TranscriptCleaner.groqEndpoint, model: model, vocabulary: prompt, apiKey: groqKey)
    groqCleaner.reasoningEffort = ProcessInfo.processInfo.environment["BENCH_REASONING"]
    let cleaner: TranscriptCleaner = args[2] == "local"
        ? makeLocalCleaner(model: model)
        : args[2] == "groq"
            ? groqCleaner
            : TranscriptCleaner(transport: URLSessionTransport(timeout: 10), model: model, vocabulary: prompt, apiKey: key)
    await cleaner.warmUp()
    var passed = 0
    for (i, c) in evalCases.enumerated() {
        do {
            let (out, _) = try await cleaner.cleanWithStats(c.input)
            let misses = score(c, out)
            if misses.isEmpty { passed += 1 }
            print("case \(i + 1) \(misses.isEmpty ? "PASS" : "FAIL") \(misses.joined(separator: "; "))")
            if !misses.isEmpty, ProcessInfo.processInfo.environment["EVAL_SHOW"] == "1" { print("   out: \(out)") }
        } catch {
            print("case \(i + 1) ERROR \(error)")
        }
    }
    print("EVAL \(args[2]) \(model) \(passed)/\(evalCases.count)")
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
    print("RESULT \(args[1]) \(args[2].split(separator: "/").last ?? "") \(ProcessInfo.processInfo.environment["BENCH_NO_PREDICTION"] == "1" ? "prediction=off " : "") n=\(results.count) p50_ms=\(p50(results)) min_ms=\(results.min()!) max_ms=\(results.max()!)")
}
