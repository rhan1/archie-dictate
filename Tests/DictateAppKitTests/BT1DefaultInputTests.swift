import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// BT1 (v1.19) through the real `AudioRecorder` on fakes only (the AUHAL headset arm, a fake built-in
/// unit, a fake route whose default input and its change notification the test drives, a private
/// lease broker). Certifies POLICY, not acoustics. No audio device is queried or opened.
@Suite("BT1DefaultInput", .serialized)
struct BT1DefaultInputTests {
    typealias Log = CaptureLeaseRecorderTests.Log

    /// The system default input as the test sets it, and the recorder's watch on it.
    final class Route: @unchecked Sendable {
        private let lock = NSLock()
        private var current: UInt32
        private var handler: ((UInt32?) -> Void)?
        private(set) var watches = 0
        let hasBuiltin: Bool
        init(default device: UInt32, hasBuiltin: Bool = true) { current = device; self.hasBuiltin = hasBuiltin }
        final class Token {}
        /// The user (or macOS) picks another default input: the property changes, then the listener fires.
        func change(to device: UInt32) {
            let fire = lock.withLock { () -> ((UInt32?) -> Void)? in current = device; return handler }
            fire?(device)
        }
        var probe: CaptureRouteProbe {
            var probe = CaptureRouteProbe(eligibility: { [hasBuiltin] in (.bluetooth, hasBuiltin) },
                                          defaultInput: { [self] in lock.withLock { current } },
                                          uid: { "dev-\($0)" }, defaultInputName: { "WH-1000XM6" })
            probe.watchDefaultInput = { [self] handler in
                lock.withLock { self.handler = handler; watches += 1 }
                return Token()
            }
            return probe
        }
    }

    final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        /// The message part of `[<iso8601>] dictate: <message>`.
        var all: [String] { lock.withLock { lines.map { $0.components(separatedBy: "dictate: ").last ?? $0 } } }
    }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = now() + timeout
        while now() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// The headset (device 101) carries; mid-dictation the default input becomes the built-in (81) while
    /// the old headset stays connected and keeps delivering. Defined behaviour: the built-in carries the
    /// rest of the dictation, resumed exactly where the headset stopped (nothing lost, nothing doubled),
    /// the client on the old device is stopped and nothing restarts it; the next dictation binds to 81.
    @Test func defaultInputChangeMidDictationHandsTheRestToTheBuiltin() async throws {
        let log = Log(), notes = Notes()
        AppController.setNoteSink { notes.append($0) }
        defer { AppController.setNoteSink(nil) }
        let builtin = CaptureLeaseRecorderTests.FakeBuiltin("A.builtin", log)
        let headset = CaptureLeaseRecorderTests.FakeHeadset("A.headset", log)
        let route = Route(default: 101)
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .auhal,
                                     broker: CaptureLeaseBroker(), route: route.probe)
        try await recorder.startAsync(device: .default)
        #expect(log.all.contains("A.headset.start uid=dev-101"))
        recorder.resetCapture()
        var t = Self.now()
        for step in 0..<10 {                                       // the headset takes over at ~0.45 s
            builtin.deliver(0.25, at: t, session: 0)
            if step >= 3 { headset.deliver(0.1, at: t) }
            t += 0.1
        }
        route.change(to: 81)
        let handled = await Self.waitUntil(0.5) {
            notes.all.contains { $0.hasPrefix("default_input_changed from=101 to=81") }
        }
        for _ in 10..<20 {                                         // the old headset is still connected
            builtin.deliver(0.25, at: t, session: 0)
            headset.deliver(0.1, at: t)
            t += 0.1
        }
        try await Task.sleep(nanoseconds: 300_000_000)            // any recovery against the old device would run here
        let captured = recorder.stop()
        let lost = 20 * 2_400 - captured.count
        let tail = captured.suffix(10 * 2_400)
        let carrierAfter = tail.allSatisfy { $0 == 0.25 } ? "builtin" : tail.contains(0.1) ? "old_headset" : "mixed"
        let headsetStarts = log.all.filter { $0.hasPrefix("A.headset.start") }.count
        let green = handled && carrierAfter == "builtin" && lost == 0 && headsetStarts == 1
        print("BT1 \(green ? "GREEN" : "RED") default_input_changed from=101 to=81 handled=\(handled ? 1 : 0)"
              + " carrier_after=\(carrierAfter) session_continued=\(captured.count >= 20 * 2_400 ? 1 : 0) lost=\(lost)"
              + " old_device_client_starts=\(headsetStarts)")
        #expect(route.watches == 1)
        #expect(handled)
        #expect(notes.all.contains("default_input_changed from=101 to=81 action=builtin_carries headset_stopped=1"))
        #expect(notes.all.contains("bridge_switchback=1 reason=default_input_changed"))
        #expect(carrierAfter == "builtin")
        #expect(lost == 0)                                        // continuous from the boundary: 2.0 s of frames
        #expect(Array(captured.prefix(4 * 2_400)).allSatisfy { $0 == 0.25 })
        #expect(log.all.contains("A.headset.stop.end"))
        #expect(headsetStarts == 1)                               // nothing re-opened the old device
        #expect(recorder.stats.carrier.hasPrefix("builtin:0-") && recorder.stats.carrier.contains(",headset:"))
        #expect(recorder.stats.carrier.components(separatedBy: ",").last?.hasPrefix("builtin:") == true)
        #expect(await recorder.awaitRelease() == .released)
    }

    /// No built-in in the device set (lid closed / desktop): nothing else can carry, so the headset the
    /// dictation started on keeps carrying — named in one line, nothing lost, no crash.
    @Test func defaultInputChangeWithoutABuiltinKeepsTheHeadset() async throws {
        let log = Log(), notes = Notes()
        AppController.setNoteSink { notes.append($0) }
        defer { AppController.setNoteSink(nil) }
        let builtin = CaptureLeaseRecorderTests.FakeBuiltin("B.builtin", log)
        let headset = CaptureLeaseRecorderTests.FakeHeadset("B.headset", log)
        let route = Route(default: 101, hasBuiltin: false)
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .auhal,
                                     broker: CaptureLeaseBroker(), route: route.probe)
        try await recorder.startAsync(device: .default)
        recorder.resetCapture()
        var t = Self.now()
        for _ in 0..<5 { headset.deliver(0.1, at: t); t += 0.1 }
        route.change(to: 81)
        let handled = await Self.waitUntil(0.5) { notes.all.contains { $0.hasPrefix("default_input_changed from=101 to=81") } }
        for _ in 5..<10 { headset.deliver(0.1, at: t); t += 0.1 }
        let beforeStop = log.all
        let captured = recorder.stop()
        let lost = 10 * 2_400 - captured.count
        print("BT1 \(handled && lost == 0 ? "GREEN" : "RED") default_input_changed from=101 to=81 builtin=absent"
              + " handled=\(handled ? 1 : 0) session_continued=\(captured.allSatisfy { $0 == 0.1 } ? 1 : 0) lost=\(lost)")
        #expect(handled)
        #expect(notes.all.contains("default_input_changed from=101 to=81 action=headset_continues reason=no_builtin"))
        #expect(lost == 0 && captured.allSatisfy { $0 == 0.1 })
        #expect(!beforeStop.contains("B.headset.stop.begin"))        // only stop() ends the client
        #expect(beforeStop.filter { $0.hasPrefix("B.headset.start") } == ["B.headset.start uid=dev-101"])
        #expect(!log.all.contains("B.builtin.start"))
    }

    /// ASTRA §K, through the recorder: headset digital silence with NO built-in device — no built-in unit
    /// is ever started (no fallback against a missing device), one explicit stage line names it, and the
    /// headset's frames (zeros, then the voice) are all in the dictation.
    @Test func noBuiltinDeviceSetNeverStartsAFallbackAndKeepsTheDictation() async throws {
        let log = Log(), notes = Notes()
        AppController.setNoteSink { notes.append($0) }
        defer { AppController.setNoteSink(nil) }
        let builtin = CaptureLeaseRecorderTests.FakeBuiltin("C.builtin", log)
        let headset = CaptureLeaseRecorderTests.FakeHeadset("C.headset", log)
        let route = Route(default: 101, hasBuiltin: false)
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .auhal,
                                     broker: CaptureLeaseBroker(), route: route.probe)
        try await recorder.startAsync(device: .default)
        recorder.resetCapture()
        var t = Self.now()
        for step in 0..<10 { headset.deliver(step < 5 ? 0 : 0.1, at: t); t += 0.1 }   // 0.5 s of exact zeros, then voice
        let captured = recorder.stop()
        let builtinStarts = log.all.filter { $0 == "C.builtin.start" }.count
        let stage = notes.all.contains("bridge_src=none reason=no_builtin")
        let fallbackLines = notes.all.filter { $0.contains("builtin_fallback") }.count
        let lost = 10 * 2_400 - captured.count
        let outcome = recorder.stats.carrier.hasPrefix("headset:0-") && !recorder.stats.carrier.contains(",") ? "headset_carries" : recorder.stats.carrier
        print("BT1 CONTROL no_builtin fallback_attempted=\(builtinStarts + fallbackLines) outcome=\(outcome)"
              + " stage=\(stage ? "bridge_src=none_reason=no_builtin" : "missing") lost=\(lost)")
        #expect(builtinStarts == 0 && fallbackLines == 0)
        #expect(stage)
        #expect(outcome == "headset_carries")
        #expect(lost == 0)
        #expect(captured.suffix(5 * 2_400).allSatisfy { $0 == 0.1 })
    }
}
