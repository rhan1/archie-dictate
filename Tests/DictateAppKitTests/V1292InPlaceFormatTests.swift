import AVFoundation
import CoreAudio
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

/// 1.29.2 D2: a conversation's first in-place apply after an A2DP→HFP switch. The headset input now runs at 16 kHz
/// while the stopped engine's input-node output bus still holds the 44.1 kHz client format it had on A2DP
/// (live 11-06: `bt_reattach_converted=1 hw=16000Hz/1ch out=44100Hz/1ch`, then `-10868`, then a rebuild).
///
/// The fake node (`V129InPlaceRouteApplyTests.FakeEngine`) models the native contract only: hardware and output
/// formats are separate values, a nil tap leaves the output as it is, an explicit tap format sets it, `start()`
/// throws `com.apple.coreaudio.avfaudio -10868` iff they disagree, and a rebuilt engine binds the current hardware.
/// The REAL `applyPendingConversationDeviceChange` runs (same device ID + UID, engine stopped, hardware changed only).
@Suite("V1292InPlaceFormatTests", .serialized)
struct V1292InPlaceFormatTests {
    typealias V129 = V129InPlaceRouteApplyTests

    static func format(_ rate: Double, _ channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    }

    static func show(_ f: AVAudioFormat?) -> String { f.map { String(Int($0.sampleRate)) } ?? "nil" }

    struct Outcome {
        let gen1: String, rebuilds: Int, sameEngine: Bool
        let requested: AVAudioFormat??, outBefore: AVAudioFormat, outAfter: AVAudioFormat
        let startError: String, applyStarts: Int, note: String
    }

    /// Starts a Bluetooth conversation at `initial`, lets the engine stop itself, changes ONLY the headset's
    /// hardware format to `changed` (nil: unchanged), admits the route generation and runs the real public apply.
    static func run(initial: AVAudioFormat, changed: AVAudioFormat?, at time: TimeInterval = ProcessInfo.processInfo.systemUptime,
                    keep: ((V129.Session) async throws -> Void)? = nil) async throws -> Outcome {
        let rig = V129.Rig(hardware: initial)
        let s = try V129.start(rig, at: time)
        let engine = rig.engine
        engine.running = false                                    // the HFP bring-up stopped the engine
        if let changed { rig.hardware = changed }                 // the device moved; the client bus did not
        let outBefore = engine.output
        let (_, _, startsBefore) = engine.counts
        let tapsBefore = engine.tapFormats.count
        s.recorder.observeConversationRoute(invalidated: true)
        #expect(try await s.recorder.applyPendingConversationDeviceChange())
        let note = s.recorder.conversationApplyNote
        let newTaps = engine.tapFormats.dropFirst(tapsBefore)
        let outcome = Outcome(
            gen1: V129.outcome(note) == "I" ? "in_place" : "rebuild", rebuilds: rig.rebuilds, sameEngine: rig.engine === engine,
            requested: newTaps.first, outBefore: outBefore, outAfter: engine.output,
            startError: engine.startErrors.last.map { String($0.code) } ?? "none",
            applyStarts: engine.counts.starts - startsBefore, note: note)
        try await keep?(s)
        _ = s.recorder.stop()
        _ = await s.recorder.awaitRelease()
        return outcome
    }

    @Test func staleOutputBusIsReconciledAndTheFirstApplyStaysInPlace() async throws {
        let o = try await Self.run(initial: Self.format(44_100), changed: Self.format(16_000))
        let green = o.gen1 == "in_place"
        let requested = o.requested.flatMap { $0 }
        print("D2 \(green ? "GREEN" : "RED") hw=16000 out_before=\(Self.show(o.outBefore)) requested_tap=\(Self.show(requested))"
            + (green ? " out_after=\(Self.show(o.outAfter))" : "")
            + " start_error=\(o.startError) gen1=\(o.gen1)"
            + (green ? " rebuilds=\(o.rebuilds) engine_identity=\(o.sameEngine ? "same" : "new")" : "")
            + " note=\(o.note)")
        #expect(o.gen1 == "in_place")
        #expect(o.rebuilds == 0 && o.sameEngine)
        #expect(requested?.sampleRate == 16_000 && requested?.channelCount == 1)
        #expect(o.outAfter.sampleRate == 16_000)
        #expect(o.startError == "none")
        #expect(o.note.hasPrefix("conv_apply=in_place reason=same_device bound=77/\"\(V129.sonyUID)\" consecutive=1 gen=1"))
    }

    @Test func generalRateChangesAreReconciled() async throws {
        for (from, to) in [(48_000.0, 16_000.0), (48_000.0, 24_000.0)] {
            let o = try await Self.run(initial: Self.format(from), changed: Self.format(to))
            let requested = o.requested.flatMap { $0 }
            print("D2 \(o.gen1 == "in_place" ? "GREEN" : "RED") \(Int(from))->\(Int(to)) hw=\(Int(to)) out_before=\(Self.show(o.outBefore)) requested_tap=\(Self.show(requested)) out_after=\(Self.show(o.outAfter)) start_error=\(o.startError) gen1=\(o.gen1) rebuilds=\(o.rebuilds) engine_identity=\(o.sameEngine ? "same" : "new")")
            #expect(o.gen1 == "in_place" && o.rebuilds == 0 && o.sameEngine)
            #expect(requested?.sampleRate == to)
            #expect(o.outAfter.sampleRate == to && o.startError == "none")
        }
    }

    @Test func equalFormatsKeepTheNilTap() async throws {
        let o = try await Self.run(initial: Self.format(16_000), changed: nil)
        let requested = o.requested.flatMap { $0 }
        print("D2 CONTROL equal hw=16000 out=\(Self.show(o.outBefore)) requested_tap=\(Self.show(requested)) gen1=\(o.gen1) rebuilds=\(o.rebuilds)")
        #expect(o.requested != nil && requested == nil)           // a tap was installed, with format nil
        #expect(o.gen1 == "in_place" && o.rebuilds == 0 && o.sameEngine)
    }

    @Test func invalidHardwareFormatNeverStartsNativelyAndRebuilds() async throws {
        let invalid = AVAudioFormat()                             // 0 Hz / 0 channels: what a vanished input reads
        #expect(invalid.sampleRate == 0 && invalid.channelCount == 0)
        let o = try await Self.run(initial: Self.format(44_100), changed: invalid)
        print("D2 CONTROL invalid hw=\(Int(invalid.sampleRate)) native_starts=\(o.applyStarts) gen1=\(o.gen1) rebuilds=\(o.rebuilds) note=\(o.note)")
        #expect(o.applyStarts == 0)
        #expect(o.gen1 == "rebuild" && o.rebuilds == 1)
        #expect(o.note.hasPrefix("conv_apply=rebuild reason=in_place_failed"))
    }

    @Test func reconciledSixteenKilohertzStreamReachesConsumeAt24kMono() async throws {
        let t0 = ProcessInfo.processInfo.systemUptime - 3
        final class Chunks: @unchecked Sendable {
            let lock = NSLock(); var pcm: [Int16] = []
            func add(_ c: [Int16]) { lock.withLock { pcm += c } }
        }
        let chunks = Chunks()
        var kept = 0, peak = 0
        let o = try await Self.run(initial: Self.format(44_100), changed: Self.format(16_000), at: t0) { s in
            s.recorder.onPCMChunk = { chunks.add($0) }
            let base = s.recorder.retainedFrameCount
            for i in 0..<10 {                                     // 1 s of 16 kHz mono, contiguous host times
                s.rig.engine.deliver(V129.sine(rate: 16_000, channels: 1, frames: 1_600), at: t0 + 1 + Double(i) * 0.1)
            }
            s.recorder.offlineDrainPCM()
            kept = s.recorder.retainedFrameCount - base
            peak = chunks.lock.withLock { chunks.pcm.map { abs(Int($0)) }.max() ?? 0 }
        }
        print("D2 CONVERT frames_per_s=\(kept) in=16000Hz/1ch gen1=\(o.gen1) peak=\(peak)")
        #expect(o.gen1 == "in_place")
        #expect(kept >= 23_500 && kept <= 24_000)
        #expect(peak > 5_000 && peak < 12_000)
    }
}
