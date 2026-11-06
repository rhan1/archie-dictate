import AVFoundation
import CoreAudio
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

/// The real dictation configuration retap and headset restart, with only native engine/route IO faked.
/// A running notification establishes Bluetooth's format generation through production admission;
/// the admitted obligation entry then runs configurationChanged → installTapAndStart → the seam's
/// unit → the unchanged offlineInstallConvertingTapAndStart → the production converting installer.
@Suite("V1293DictationRetapFormatTests", .serialized)
struct V1293DictationRetapFormatTests {
    typealias V129 = V129InPlaceRouteApplyTests
    typealias D1 = V1292RestartCancelTests
    typealias Session = V1292RestartCancelTests.Session
    static func format(_ rate: Double, _ channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    }
    static func show(_ format: AVAudioFormat?) -> String { format.map { String(Int($0.sampleRate)) } ?? "nil" }

    /// V1292's dictation/bridge/lease setup, with an initial hardware argument. No existing rig/test is edited.
    /// The VPIO control configures a fake .vpio unit using the SAME graph-marker assignment as real configure,
    /// before its first start (while recorder stats are still off). Subsequent retaps retain that graph marker.
    static func start(initial: AVAudioFormat, at time: TimeInterval, vpio: Bool = false) throws -> Session {
        let rig = V129.Rig(hardware: initial)
        let watches = D1.Watches()
        let log = V61CaptureLifetimeTests.Log()
        let builtin = V61CaptureLifetimeTests.FakeBuiltin("v1293.builtin", log: log)
        let headset = V61CaptureLifetimeTests.FakeHeadset("v1293.headset", log: log)
        var probe = rig.probe
        probe.isRunningSomewhere = { _ in false }
        probe.watchDefaultInput = { _ in watches.make() }
        let broker = CaptureLeaseBroker()
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .engine, broker: broker, route: probe)
        recorder.kind = .dictation
        final class ConfigureOnce { var pending: Bool; init(_ pending: Bool) { self.pending = pending } }
        let configure = ConfigureOnce(vpio)
        let make: (CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit = { [weak recorder] _ in
            CaptureInputUnit(start: {
                if configure.pending {
                    configure.pending = false
                    _ = try CaptureVoiceProcessing.start(requested: true, builtin: true, bluetooth: false, make: { unit in
                        #expect(unit == .vpio)
                        return CaptureInputUnit(start: { try recorder?.offlineInstallConvertingTapAndStart() }, dispose: {},
                                                configure: { _ in recorder?.offlineVoiceProcessingConfigure() })
                    }, note: { _ in })
                } else {
                    try recorder?.offlineInstallConvertingTapAndStart()
                }
            }, dispose: {})
        }
        recorder.offlineConversationEngine = OfflineConversationEngine(
            native: { rig.engine.native }, rebuild: { try rig.rebuild() }, make: make)
        try recorder.offlineStartInput(at: time, note: { _ in }, bridge: true, make: make)
        return Session(recorder: recorder, rig: rig, broker: broker, watches: watches)
    }

    struct Outcome {
        let hardware: AVAudioFormat, before: AVAudioFormat, after: AVAudioFormat
        let taps: [AVAudioFormat?], startError: String, nativeStarts: Int, successfulStarts: Int
        let result: String, running: Bool, rebuilds: Int, sameEngine: Bool, notes: [String], requests: Int
        let errors: [(domain: String, code: Int)]
        var requested: AVAudioFormat? { taps.first.flatMap { $0 } }
        var green: Bool {
            requested.map { V129.FakeEngine.agree($0, hardware) } == true
                && V129.FakeEngine.agree(after, hardware) && startError == "none"
                && result == "retapped" && running && rebuilds == 0 && sameEngine
        }
    }

    /// Snapshots on the executor, before any failed-retap restart can mask the outcome. Failed cases stop
    /// immediately AFTER the snapshot, retaining the real restart request counter and error diagnostics.
    static func run(initial: AVAudioFormat = format(44_100), changed: AVAudioFormat,
                    running: Bool = false, vpio: Bool = false,
                    keep: ((Session, Outcome, TimeInterval) throws -> Void)? = nil) async throws -> Outcome {
        let t0 = ProcessInfo.processInfo.systemUptime - 3
        let s = try start(initial: initial, at: t0, vpio: vpio)
        do {
            let engine = s.rig.engine
            #expect(engine.running)
            let tapsAtStart = engine.tapFormats.count
            // Real observer policy: a running BT notification increments formatGeneration and leaves IO alone.
            #expect(s.recorder.offlineConfigurationReattach(at: t0, admitted: false))
            #expect(engine.tapFormats.count == tapsAtStart)
            #expect(s.recorder.stats.configChanges == 0)
            engine.running = running
            s.rig.hardware = changed                         // hardware ONLY; output bus retains initial format
            let before = engine.output
            let starts = engine.counts.starts, successful = engine.startTimes.count
            let taps = engine.tapFormats.count, notes = s.recorder.retapDiagnostics.count
            let requests = s.recorder.headsetRestartDiagnostics.requests
            let errors = s.recorder.retapErrorDiagnostics.count
            var captured: Outcome?
            #expect(s.recorder.offlineConfigurationReattach(at: t0 + 1, completion: {
                let lines = Array(s.recorder.retapDiagnostics.dropFirst(notes))
                let failed = lines.contains { $0.hasPrefix("config_retap_error=") }
                captured = Outcome(hardware: engine.hardware, before: before, after: engine.output,
                                   taps: Array(engine.tapFormats.dropFirst(taps)),
                                   startError: engine.startErrors.last.map { String($0.code) } ?? "none",
                                   nativeStarts: engine.counts.starts - starts,
                                   successfulStarts: engine.startTimes.count - successful,
                                   result: failed ? "failed" : (s.recorder.stats.configChanges == 1 ? "retapped" : "skipped"),
                                   running: engine.running, rebuilds: s.rig.rebuilds, sameEngine: s.rig.engine === engine,
                                   notes: lines, requests: s.recorder.headsetRestartDiagnostics.requests - requests,
                                   errors: Array(s.recorder.retapErrorDiagnostics.dropFirst(errors)))
                if failed { _ = s.recorder.stop() }
            }))
            let o = try #require(captured)
            try keep?(s, o, t0)
            #expect(await D1.finish(s) == .released)
            return o
        } catch {
            _ = await D1.finish(s)
            throw error
        }
    }

    static func expectGreen(_ o: Outcome) {
        #expect(o.green)
        #expect(o.taps.count == 1)
        #expect(o.requested?.sampleRate == o.hardware.sampleRate)
        #expect(o.requested?.channelCount == o.hardware.channelCount)
        #expect(o.startError == "none")
        #expect(o.result == "retapped" && o.running)
        #expect(o.rebuilds == 0 && o.sameEngine)
        #expect(!o.notes.contains { $0.hasPrefix("config_retap_error=") })
        #expect(o.notes.contains { $0.hasPrefix("bt_reattach_reformatted=1") })
    }

    @Test func stoppedDictationRetapRepinsTheSameEngine() async throws {
        let o = try await Self.run(changed: Self.format(16_000))
        print("D3 \(o.green ? "GREEN" : "RED") hw=\(Self.show(o.hardware)) out_before=\(Self.show(o.before)) requested_tap=\(Self.show(o.requested))"
              + (o.green ? " out_after=\(Self.show(o.after))" : "")
              + " start_error=\(o.startError) retap=\(o.result) running=\(o.running ? 1 : 0)"
              + (o.green ? " rebuilds=\(o.rebuilds) engine_identity=\(o.sameEngine ? "same" : "new")" : ""))
        Self.expectGreen(o)
    }

    @Test func equalFormatsKeepNil() async throws {
        let o = try await Self.run(initial: Self.format(16_000), changed: Self.format(16_000))
        print("D3 CONTROL equal hw=\(Self.show(o.hardware)) out=\(Self.show(o.before)) requested_tap=\(Self.show(o.requested))")
        #expect(o.taps.count == 1 && o.requested == nil)
        #expect(o.startError == "none" && o.result == "retapped" && o.running)
    }

    @Test func runningGraphKeepsNil() async throws {
        let o = try await Self.run(changed: Self.format(16_000), running: true)
        print("D3 CONTROL running hw=\(Self.show(o.hardware)) out=\(Self.show(o.before)) requested_tap=\(Self.show(o.requested)) start_error=\(o.startError)")
        #expect(o.taps.count == 1 && o.requested == nil)
    }

    @Test func voiceProcessingGraphKeepsNilEvenWhileStatsAreOff() async throws {
        let o = try await Self.run(changed: Self.format(16_000), vpio: true)
        print("D3 CONTROL vpio requested_tap=\(Self.show(o.requested))")
        #expect(o.taps.count == 1 && o.requested == nil)
    }

    @Test func invalidHardwareNeverStartsAndRequestsExistingRecovery() async throws {
        let invalid = AVAudioFormat()
        let o = try await Self.run(changed: invalid)
        print("D3 CONTROL invalid hw=\(Self.show(o.hardware)) native_starts=\(o.nativeStarts)")
        #expect(invalid.sampleRate == 0 && invalid.channelCount == 0)
        #expect(o.nativeStarts == 0 && o.successfulStarts == 0)
        #expect(o.result == "failed")
        #expect(o.notes.contains { $0 == "config_retap_error=in_place_format:invalid_hardware" })
        #expect(o.errors.contains { $0.domain == "dictate.in_place_format" && $0.code == 1 })
        #expect(o.requests == 1)
    }

    @Test func headsetRestartRepinsHardwareThatChangesAfterRebuild() async throws {
        let s = try Self.start(initial: Self.format(44_100), at: ProcessInfo.processInfo.systemUptime)
        // The hook is AFTER a new engine binds 44.1 kHz, BEFORE installTapAndStart(make: offline.make).
        s.rig.onNewEngine = { engine in engine.hardware = Self.format(16_000) }
        let line = D1.silentHeadsetUntilRestart(s)
        let candidate = s.rig.engines.dropFirst().first
        let requested = candidate?.tapFormats.first.flatMap { $0 }
        let error = candidate?.startErrors.last.map { String($0.code) } ?? "none"
        let green = requested?.sampleRate == 16_000 && error == "none" && candidate?.running == true
        print("D3 \(green ? "GREEN" : "RED") restart-after-rebuild hw=\(Self.show(candidate?.hardware)) requested_tap=\(Self.show(requested))"
              + (green ? "" : " start_error=\(error)"))
        #expect(await D1.finish(s) == .released)
        #expect(line != nil)
        #expect(s.rig.rebuilds == 1)
        #expect(green)
        #expect(candidate?.output.sampleRate == 16_000)
        #expect(V129.field("started", line ?? "") == "1")
    }

    @Test(arguments: [(48_000.0, 16_000.0), (48_000.0, 24_000.0)])
    func otherRatesRepin(_ rates: (Double, Double)) async throws {
        let o = try await Self.run(initial: Self.format(rates.0), changed: Self.format(rates.1))
        print("D3 \(o.green ? "GREEN" : "RED") \(Self.show(o.before))->\(Self.show(o.hardware)) requested_tap=\(Self.show(o.requested)) out_after=\(Self.show(o.after)) start_error=\(o.startError)")
        Self.expectGreen(o)
    }

    @Test func channelCountChangeRepins() async throws {
        let o = try await Self.run(initial: Self.format(48_000, 2), changed: Self.format(48_000, 1))
        let tap = o.requested.map { "\(Self.show($0))x\($0.channelCount)" } ?? "nil"
        print("D3 \(o.green ? "GREEN" : "RED") \(Self.show(o.before))x\(o.before.channelCount)->\(Self.show(o.hardware))x\(o.hardware.channelCount) requested_tap=\(tap) out_after=\(Self.show(o.after))x\(o.after.channelCount) start_error=\(o.startError)")
        Self.expectGreen(o)
    }

    @Test func retappedPCMConvertsTo24kMono() async throws {
        final class Chunks: @unchecked Sendable {
            let lock = NSLock(); var pcm: [Int16] = []
            func add(_ samples: [Int16]) { lock.withLock { pcm += samples } }
        }
        let chunks = Chunks()
        var frames = 0, peak = 0
        let o = try await Self.run(changed: Self.format(16_000)) { s, o, t0 in
            guard o.green else { return }                     // a refused start cannot deliver native PCM
            s.recorder.onPCMChunk = { chunks.add($0) }
            let base = s.recorder.retainedFrameCount
            for i in 0..<10 {
                s.rig.engine.deliver(V129.sine(rate: 16_000, channels: 1, frames: 1_600, amplitude: 0.3),
                                     at: t0 + 1 + Double(i) * 0.1)
            }
            s.recorder.offlineDrainPCM()
            frames = s.recorder.retainedFrameCount - base
            peak = chunks.lock.withLock { chunks.pcm.map { abs(Int($0)) }.max() ?? 0 }
        }
        print("D3 CONVERT frames_per_s=\(frames)")
        Self.expectGreen(o)
        #expect(frames >= 23_000 && frames <= 25_000)
        #expect(peak > 5_000 && peak < 12_000)
    }
}
