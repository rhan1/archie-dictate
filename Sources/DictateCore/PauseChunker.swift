import Foundation

/// Pure 24 kHz mono PCM chunking. Quiet runs use 50 ms windows; forced
/// cuts choose the quietest complete 100 ms window in the last second.
public struct PauseChunker: Sendable {
    public struct Chunk: Sendable, Equatable {
        public let index: Int
        public let samples: [Int16]
        public init(index: Int, samples: [Int16]) {
            self.index = index
            self.samples = samples
        }
    }

    public static let sampleRate = 24_000
    public static let windowSamples = 1_200
    private var samples: [Int16] = []
    private var windows: [Double] = []
    private var floor = WisprLevel()
    private var quietStart: Int?
    private var nextIndex = 0
    private var finished = false

    public init() {}

    public mutating func append(_ pcm: [Int16]) -> [Chunk] {
        guard !finished else { return [] }
        var emitted: [Chunk] = []
        // Consume incrementally, so even a large input obeys the 3 s / 6 s caps.
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
            let minimum = (firstChunk ? 2 : 4) * Self.sampleRate
            let quietSamples = firstChunk ? 3_600 : 6_000
            let maximum = (firstChunk ? 3 : 6) * Self.sampleRate
            if let quietStart {
                // Silence beginning before the minimum must also supply the
                // required quiet run AFTER that minimum boundary.
                let pause = max(quietStart, minimum)
                if samples.count - pause >= quietSamples {
                    emitted.append(cut(at: pause))
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
                emitted.append(cut(at: quietest * Self.windowSamples))
            }
        }
        return emitted
    }

    private mutating func cut(at count: Int) -> Chunk {
        let chunk = Chunk(index: nextIndex, samples: Array(samples.prefix(count)))
        nextIndex += 1
        samples.removeFirst(count)
        windows.removeFirst(count / Self.windowSamples)
        quietStart = quietStart.map { max(0, $0 - count) }
        return chunk
    }

    /// The caller decides whether a final partial is long enough to upload.
    public mutating func finish() -> [Chunk] {
        guard !finished else { return [] }
        finished = true
        guard !samples.isEmpty else { return [] }
        let chunk = Chunk(index: nextIndex, samples: samples)
        samples.removeAll()
        windows.removeAll()
        return [chunk]
    }
}
