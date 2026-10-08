// Latency harness for gate G6 and the A3 cleanup-model choice. Prints only
// counts and milliseconds — never transcript text, never the key.
//   DictateBench stt-realtime <fixture.wav> <runs>   stream at real-time pace, time commit -> final
//   DictateBench stt-batch    <fixture.wav> <runs>   v1 path: time upload+transcribe after finish
//   DictateBench cleanup      <model> <runs>         time one cleanup completion on a 40-word fixture
import DictateCore
import Foundation

let vocabURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects/-Users-razakhan/memory/reference-raza-vocabulary.md")
let prompt = Vocabulary.buildPrompt(fileURL: vocabURL)
let key: @Sendable () throws -> String = { try KeychainAPIKey.read() }

/// 40 words of spoken-style text with fillers and a self-correction.
let cleanupFixture = "um so I think we should uh send the Limpar report to the team on Tuesday no actually Wednesday and you know make sure the turnout watch numbers are like double checked before anyone shares it outside"

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
guard args.count >= 4 else {
    print("usage: DictateBench stt-realtime|stt-batch <wav> <runs> | cleanup <model> <runs>")
    exit(2)
}
let runs = Int(args[3]) ?? 5
var results: [Int] = []

switch args[1] {
case "stt-realtime":
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2]))
    print("fixture samples=\(pcm.count) seconds=\(String(format: "%.1f", Double(pcm.count) / 24_000))")
    for run in 1...runs {
        let transcriber = RealtimeTranscriber(transport: URLSessionWebSocketTransport(), prompt: prompt, apiKey: key)
        let openStart = DispatchTime.now()
        do { try await transcriber.open(timeout: Double(ProcessInfo.processInfo.environment["BENCH_OPEN_TIMEOUT"] ?? "1.5") ?? 1.5) } catch { print("run \(run) open error=\(error)"); continue }
        let openMs = ms(since: openStart)
        // Real-time pace, 100 ms chunks, like the microphone.
        let chunk = 2_400
        for start in stride(from: 0, to: pcm.count, by: chunk) {
            transcriber.append(Array(pcm[start..<min(pcm.count, start + chunk)]))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // The mic keeps streaming quiet audio between the last word and the
        // finish tap; BENCH_TAIL_MS models that reaction time (0 = tap instantly).
        let tailMs = Int(ProcessInfo.processInfo.environment["BENCH_TAIL_MS"] ?? "0") ?? 0
        for _ in stride(from: 0, to: tailMs, by: 100) {
            transcriber.append([Int16](repeating: 0, count: chunk))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let commit = DispatchTime.now()
        FileHandle.standardError.write(Data("rt \(commit.uptimeNanoseconds / 1_000_000) FINISH\n".utf8))
        do {
            let text = try await transcriber.finish()
            let elapsed = ms(since: commit)
            results.append(elapsed)
            print("run \(run) open_ms=\(openMs) tail_ms=\(tailMs) finish_to_final_ms=\(elapsed) segments=\(transcriber.segmentCount) chars=\(text.count)")
        } catch {
            print("run \(run) finish error=\(error)")
        }
        transcriber.close()
    }
case "stt-batch":
    let pcm = try samples(fromWAV: URL(fileURLWithPath: args[2]))
    let wav = WAVEncoder.encode(samples: pcm, sampleRate: 24_000)
    let client = TranscriptionClient(transport: URLSessionTransport(timeout: 60), apiKey: key)
    for run in 1...runs {
        let start = DispatchTime.now()
        do {
            let text = try await client.transcribe(wav: wav, prompt: prompt)
            let elapsed = ms(since: start)
            results.append(elapsed)
            print("run \(run) finish_to_final_ms=\(elapsed) bytes=\(wav.count) chars=\(text.count)")
        } catch {
            print("run \(run) error=\(error)")
        }
    }
case "cleanup":
    var cleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: 10), model: args[2], vocabulary: prompt, apiKey: key)
    cleaner.usePrediction = ProcessInfo.processInfo.environment["BENCH_NO_PREDICTION"] != "1"
    print("prediction=\(cleaner.usePrediction)")
    // One unmeasured call warms the keep-alive connection, as the app does during recording.
    _ = try? await cleaner.clean(cleanupFixture)
    for run in 1...runs {
        let start = DispatchTime.now()
        do {
            let text = try await cleaner.clean(cleanupFixture)
            let elapsed = ms(since: start)
            results.append(elapsed)
            print("run \(run) model=\(args[2]) cleanup_ms=\(elapsed) words_in=\(cleanupFixture.split(separator: " ").count) chars_out=\(text.count)")
        } catch {
            print("run \(run) model=\(args[2]) error=\(error)")
        }
    }
default:
    print("unknown command \(args[1])")
    exit(2)
}
if !results.isEmpty {
    print("RESULT \(args[1]) \(args[2].split(separator: "/").last ?? "") \(ProcessInfo.processInfo.environment["BENCH_NO_PREDICTION"] == "1" ? "prediction=off " : "") n=\(results.count) p50_ms=\(p50(results)) min_ms=\(results.min()!) max_ms=\(results.max()!)")
}
