import Foundation

/// Pure 24 kHz mono PCM chunking. Quiet runs use 50 ms windows; forced
/// cuts choose the quietest complete 100 ms window in the last second.
public struct PauseChunker: Sendable {
    /// Describes the boundary AFTER this chunk. Final split opening pieces
    /// are forced cuts; only the last piece has a final boundary.
    public enum CutKind: String, Sendable { case pause, forced, final }

    public struct Chunk: Sendable, Equatable {
        public let index: Int
        public let samples: [Int16]
        public let cutKind: CutKind
        /// Observed quiet run at a pause cut, including any quiet before the minimum.
        public let quietRunMs: Int?
        public init(index: Int, samples: [Int16], cutKind: CutKind = .final, quietRunMs: Int? = nil) {
            self.index = index
            self.samples = samples
            self.cutKind = cutKind
            self.quietRunMs = quietRunMs
        }
    }

    public static let sampleRate = 24_000
    public static let windowSamples = 1_200
    private let firstMinimumSamples: Int
    private let firstMaximumSamples: Int
    private var samples: [Int16] = []
    private var windows: [Double] = []
    private var floor = WisprLevel()
    private var quietStart: Int?
    private var nextIndex = 0
    private var finished = false

    public init(firstMinimumSeconds: Double = 3.0, firstMaximumSeconds: Double = 4.0) {
        firstMinimumSamples = Int((firstMinimumSeconds * Double(Self.sampleRate)).rounded())
        firstMaximumSamples = Int((firstMaximumSeconds * Double(Self.sampleRate)).rounded())
    }

    public mutating func append(_ pcm: [Int16]) -> [Chunk] {
        guard !finished else { return [] }
        var emitted: [Chunk] = []
        // Consume incrementally, so even a large input obeys each chunk's cap.
        var cursor = 0
        while cursor < pcm.count {
            let needed = Self.windowSamples - (samples.count % Self.windowSamples)
            let end = min(pcm.count, cursor + needed)
            samples.append(contentsOf: pcm[cursor..<end])
            cursor = end
            guard samples.count % Self.windowSamples == 0 else { continue }
            let start = samples.count - Self.windowSamples
            let rms = sqrt(samples[start...].reduce(0.0) {
                let value = Double($1) / 32768
                return $0 + value * value
            } / Double(Self.windowSamples))
            let db = 20 * log10(rms + 1e-10)
            _ = floor.level(db: db)
            let quiet = db < floor.floorDB + 8
            windows.append(db)
            if quiet {
                if quietStart == nil { quietStart = start }
            } else {
                quietStart = nil
            }
            let firstChunk = nextIndex == 0
            let minimum = firstChunk ? firstMinimumSamples : 4 * Self.sampleRate
            let quietSamples = firstChunk ? 3_600 : 6_000
            let maximum = firstChunk ? firstMaximumSamples : 6 * Self.sampleRate
            if let quietStart {
                // Silence beginning before the minimum must also supply the
                // required quiet run AFTER that minimum boundary.
                let pause = max(quietStart, minimum)
                if samples.count - pause >= quietSamples {
                    emitted.append(cut(at: pause, kind: .pause, quietRunMs: (samples.count - quietStart) * 1000 / Self.sampleRate))
                    continue
                }
            }
            if samples.count >= maximum {
                // Two 50 ms powers measure a complete 100 ms window. Ties
                // choose the latest boundary, retaining less silence.
                let first = windows.count - 20
                func power(at index: Int) -> Double {
                    pow(10, windows[index] / 10) + pow(10, windows[index + 1] / 10)
                }
                var quietest = first
                for i in (first + 1)..<(windows.count - 1) where power(at: i) <= power(at: quietest) {
                    quietest = i
                }
                emitted.append(cut(at: quietest * Self.windowSamples, kind: .forced))
            }
        }
        return emitted
    }

    private mutating func cut(at count: Int, kind: CutKind, quietRunMs: Int? = nil) -> Chunk {
        let chunk = Chunk(index: nextIndex, samples: Array(samples.prefix(count)), cutKind: kind, quietRunMs: quietRunMs)
        nextIndex += 1
        samples.removeFirst(count)
        windows.removeFirst(count / Self.windowSamples)
        quietStart = quietStart.map { max(0, $0 - count) }
        return chunk
    }

    /// The caller decides whether a final partial is long enough to upload.
    public mutating func finish(splitOver seconds: Double? = nil) -> [Chunk] {
        guard !finished else { return [] }
        finished = true
        guard !samples.isEmpty else { return [] }
        defer {
            samples.removeAll()
            windows.removeAll()
            quietStart = nil
        }
        // A speech-only partial can seed the adaptive floor from speech.
        // With no window above that floor's quiet band, use its lower bound
        // rather than discard uncalibrated speech as if it were silence.
        if windows.allSatisfy({ $0 < floor.floorDB + 8 }) {
            _ = floor.level(db: -60)
        }
        var speechEnd = samples.count
        while speechEnd > 0 {
            let start = ((speechEnd - 1) / Self.windowSamples) * Self.windowSamples
            let window = start / Self.windowSamples
            let db: Double
            if speechEnd - start == Self.windowSamples {
                db = windows[window]
            } else {
                let rms = sqrt(samples[start..<speechEnd].reduce(0.0) {
                    let value = Double($1) / 32768
                    return $0 + value * value
                } / Double(speechEnd - start))
                db = 20 * log10(rms + 1e-10)
            }
            guard db < floor.floorDB + 8 else { break }
            speechEnd = start
        }
        guard speechEnd > 0 else { return [] }
        let count = min(samples.count, speechEnd + 6_000) // At most 250 ms of quiet.
        if let seconds, seconds.isFinite, seconds >= 0.5,
           Double(count) > seconds * Double(Self.sampleRate) {
            let maximumTail = Int(min(seconds, 2.0) * Double(Self.sampleRate))
            let minimumTail = Self.sampleRate / 2
            // Boundaries align to 50 ms; each candidate measures a complete
            // 100 ms window. The cut is at its start, as for forced cuts.
            let first = max(1, (count - maximumTail + Self.windowSamples - 1) / Self.windowSamples)
            let last = min((count - minimumTail) / Self.windowSamples, windows.count - 2)
            if first <= last {
                func power(_ index: Int) -> Double {
                    pow(10, windows[index] / 10) + pow(10, windows[index + 1] / 10)
                }
                var quietest = first
                if first < last {
                    for index in (first + 1)...last where power(index) <= power(quietest) {
                        quietest = index
                    }
                }
                let split = quietest * Self.windowSamples
                return [Chunk(index: nextIndex, samples: Array(samples[..<split]), cutKind: .forced),
                        Chunk(index: nextIndex + 1, samples: Array(samples[split..<count]))]
            }
        }
        let chunk = Chunk(index: nextIndex, samples: Array(samples.prefix(count)))
        return [chunk]
    }
}
