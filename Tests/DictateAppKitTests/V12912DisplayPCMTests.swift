import AVFoundation
import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// 1.29.12 (Archie 62.8.3): the display-only per-IO-buffer copy (`onDisplayPCM`) leaves the captured audio
/// byte-identical — same 100 ms chunks, same order, same remainder — on both capture arms: the built-in
/// conversation unit (256-frame slots, the measured live size) and the engine arm (AVAudioEngine tap, 2 400).
/// Real speech when `D_DISPLAY_FIXTURES` names a dir of 24 kHz mono pcm16 WAVs (`D_DISPLAY_FIXTURE_NAMES`,
/// default brn-05,raza-passage); otherwise a synthetic voiced signal. No device, engine or microphone.
@Suite("V12912DisplayPCM", .serialized)
struct V12912DisplayPCMTests {
    typealias Box = V1296BuiltinConversationTests.Box

    static func fixtures() -> [(name: String, frames: [Float])] {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["D_DISPLAY_FIXTURES"] {
            let names = (env["D_DISPLAY_FIXTURE_NAMES"] ?? "brn-05,raza-passage").split(separator: ",").map(String.init)
            return names.compactMap { name in
                guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: "\(dir)/\(name).wav")),
                      file.fileFormat.sampleRate == 24_000,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil else { return nil }
                return (name, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
            }
        }
        let synthetic = (0..<60_000).map { i -> Float in
            let t = Double(i) / 24_000
            return Float(0.2 * sin(2 * .pi * 180 * t) * max(0, sin(2 * .pi * 4.5 * t)))
        }
        return [("synthetic", synthetic)]
    }

    struct Run { var chunks: [[Int16]]; var display: [[Int16]] }

    /// The built-in conversation arm: the real recorder fed by a fake built-in unit in `slot`-frame IO buffers.
    static func builtin(_ frames: [Float], slot: Int, display: Bool) async throws -> Run {
        let r = V1296BuiltinConversationTests.Rig()
        let shown = Box<[[Int16]]>([])
        if display { r.recorder.onDisplayPCM = { pcm in shown.update { $0.append(pcm) } } }
        try await r.start()
        for (k, start) in stride(from: 0, to: frames.count, by: slot).enumerated() {
            r.clock.value = 100 + Double(k) * Double(slot) / 24_000
            r.units.value.last!.emit(Array(frames[start..<min(start + slot, frames.count)]), at: r.clock.value)
        }
        _ = await V1296BuiltinConversationTests.eventually {
            !display || shown.value.reduce(0) { $0 + $1.count } >= r.chunks.value.reduce(0) { $0 + $1.count }
        }
        await r.stop()
        return Run(chunks: r.chunks.value, display: shown.value)
    }

    /// The engine arm: the real feed → accumulation → ordered delivery, one `tap`-frame buffer per call.
    static func engineArm(_ frames: [Float], tap: Int, display: Bool) async throws -> Run {
        let (recorder, _, _, _) = V61CaptureLifetimeTests.makeRecorder(name: "v12912", kind: .dictation)
        recorder.retainsCapturedSamples = false
        let chunks = Box<[[Int16]]>([]), shown = Box<[[Int16]]>([])
        recorder.onPCMChunk = { pcm in chunks.update { $0.append(pcm) } }
        if display { recorder.onDisplayPCM = { pcm in shown.update { $0.append(pcm) } } }
        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        for (k, start) in stride(from: 0, to: frames.count, by: tap).enumerated() {
            _ = recorder.offlineInputFrames(Array(frames[start..<min(start + tap, frames.count)]),
                                            at: Double(k + 1) * Double(tap) / 24_000)
            recorder.offlineDrainPCM()
        }
        _ = await V1296BuiltinConversationTests.eventually {
            !display || shown.value.reduce(0) { $0 + $1.count } >= chunks.value.reduce(0) { $0 + $1.count }
        }
        _ = recorder.stop()
        recorder.offlineDrainPCM()
        return Run(chunks: chunks.value, display: shown.value)
    }

    /// Same chunks (count, sizes, every sample, order) with and without the display copy; the display copy is
    /// exactly the captured stream, one entry per IO buffer. `flip` = the positive control (one sample changed).
    static func compare(_ base: Run, _ shown: Run, flip: Bool = false) -> (identical: Bool, displayMatches: Bool) {
        var chunks = shown.chunks
        if flip, let i = chunks.firstIndex(where: { !$0.isEmpty }) { chunks[i][chunks[i].count / 2] &+= 1 }
        let captured = Array(base.chunks.joined())
        let displayed = Array(shown.display.joined())
        return (base.chunks == chunks && !captured.isEmpty, displayed.count >= captured.count - 2_400 &&
                Array(displayed.prefix(captured.count)) == Array(captured.prefix(displayed.count)))
    }

    @Test func capture_samples_identical_builtin_conversation() async throws {
        for f in Self.fixtures() {
            let base = try await Self.builtin(f.frames, slot: 256, display: false)
            let after = try await Self.builtin(f.frames, slot: 256, display: true)
            let check = Self.compare(base, after), control = Self.compare(base, after, flip: true)
            #expect(base.display.isEmpty)
            #expect(check.identical && check.displayMatches)
            #expect(!control.identical)
            #expect(after.display.allSatisfy { $0.count == 256 } || after.display.dropLast().allSatisfy { $0.count == 256 })
            print("P RED control capture_samples_identical=\(control.identical ? 1 : 0) path=builtin fixture=\(f.name) (one sample flipped)")
            print("P GREEN capture_samples_identical=\(check.identical ? 1 : 0) path=builtin fixture=\(f.name) chunks=\(after.chunks.count) chunk_frames=\(after.chunks.map(\.count).max() ?? 0) display_buffers=\(after.display.count) display_frames=\(after.display.first?.count ?? 0) display_is_capture=\(check.displayMatches ? 1 : 0)")
        }
    }

    @Test func capture_samples_identical_engine_arm() async throws {
        for f in Self.fixtures() {
            for tap in [2_400, 1_024] {
                let base = try await Self.engineArm(f.frames, tap: tap, display: false)
                let after = try await Self.engineArm(f.frames, tap: tap, display: true)
                let check = Self.compare(base, after), control = Self.compare(base, after, flip: true)
                #expect(check.identical && check.displayMatches)
                #expect(!control.identical)
                print("P RED control capture_samples_identical=\(control.identical ? 1 : 0) path=engine tap=\(tap) fixture=\(f.name) (one sample flipped)")
                print("P GREEN capture_samples_identical=\(check.identical ? 1 : 0) path=engine tap=\(tap) fixture=\(f.name) chunks=\(after.chunks.count) display_buffers=\(after.display.count) display_is_capture=\(check.displayMatches ? 1 : 0)")
            }
        }
    }

    /// No display handler → no copy is queued (the production default for hosts that do not ask for it).
    @Test func no_handler_no_display_work() async throws {
        let run = try await Self.engineArm(Self.fixtures()[0].frames, tap: 2_400, display: false)
        #expect(run.display.isEmpty && !run.chunks.isEmpty)
    }
}
