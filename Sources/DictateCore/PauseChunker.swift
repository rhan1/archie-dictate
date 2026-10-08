import Foundation

/// Pure 24 kHz mono PCM chunking. All boundaries fall on 100 ms windows.
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
    public static let windowSamples = 2_400
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
        // Consume incrementally, so even a large input cannot exceed 10 s.
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
            if let pause = quietStart, samples.count >= 5 * Self.sampleRate,
               pause >= 3 * Self.sampleRate, samples.count - pause >= 6_000 {
                emitted.append(cut(at: pause))
            } else if samples.count >= 10 * Self.sampleRate {
                // Prefer the quietest window in the last 2 s. Ties choose
                // the latest boundary to avoid retaining excessive silence.
                let first = windows.count - 20
                var quietest = first
                for i in (first + 1)..<windows.count where windows[i] <= windows[quietest] {
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
