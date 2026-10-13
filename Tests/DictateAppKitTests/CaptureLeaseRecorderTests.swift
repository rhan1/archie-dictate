import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.12 L1–L3 through the real `AudioRecorder`, on fakes only: a fake built-in unit, a fake AUHAL
/// headset client (`headset_backend=auhal`), a fake route and a private lease broker. No audio
/// device is queried or opened.
@Suite("CaptureLeaseRecorder", .serialized)
struct CaptureLeaseRecorderTests {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        func index(of line: String) -> Int? { all.firstIndex(of: line) }
    }

    final class FakeBuiltin: BuiltinCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onDeviceLost: ((CaptureEpoch) -> Void)?
        let name: String
        let log: Log
        private let lock = NSLock()
        private(set) var epochs: [CaptureEpoch] = []
        private var running: CaptureEpoch?
        init(_ name: String, _ log: Log) { self.name = name; self.log = log }
        func start(epoch: CaptureEpoch) throws {
            lock.withLock { epochs.append(epoch); running = epoch }
            log.append("\(name).start")
        }
        func stop() {
            let was = lock.withLock { () -> Bool in defer { running = nil }; return running != nil }
            if was { log.append("\(name).stop") }
        }
        func stop(epoch: CaptureEpoch) { if lock.withLock({ running === epoch }) { stop() } }
        var isDelivering: Bool { true }
        var currentDeviceID: UInt32? { 81 }
        var expectedDeviceID: UInt32? { 81 }
        var lastBufferTime: TimeInterval? { nil }
        let backend = "fake"
        /// A callback stamped with the epoch of start number `session` (0-based) — late or not.
        func deliver(_ value: Float, frames: Int = 2_400, at time: TimeInterval, session: Int) {
            let epoch = lock.withLock { epochs[session] }
            onFrames?([Float](repeating: value, count: frames), time, epoch)
        }
    }

    final class FakeHeadset: HeadsetCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)?
        let name: String
        let log: Log
        /// When set, `stop()` blocks until it is signalled (a slow hardware release).
        var stopGate: DispatchSemaphore?
        private let lock = NSLock()
        private var epoch: CaptureEpoch?
        private var ioRunning = false
        init(_ name: String, _ log: Log) { self.name = name; self.log = log }
        func start(deviceUID: String, epoch: CaptureEpoch) throws {
            lock.withLock { self.epoch = epoch; ioRunning = true }
            log.append("\(name).start uid=\(deviceUID)")
            onEvent?(.started(deviceUID: deviceUID, sampleRate: 16_000, channels: 1), epoch)
        }
        func stop() {
            guard lock.withLock({ epoch != nil }) else { return }
            log.append("\(name).stop.begin")
            stopGate?.wait()
            lock.withLock { epoch = nil; ioRunning = false }
            log.append("\(name).stop.end")
        }
        func stop(epoch: CaptureEpoch) { if lock.withLock({ self.epoch === epoch }) { stop() } }
        /// The OS stopped this client's IO (the unit itself still thinks it is started).
        func ioStops() { lock.withLock { ioRunning = false } }
        var isRunning: Bool { lock.withLock { ioRunning } }
        var lastCallbackTime: TimeInterval? { nil }
        var formatGeneration: Int { 1 }
        var counters: SourceCounters { SourceCounters() }
        let backend = "auhal"
        func deliver(_ value: Float, frames: Int = 2_400, at time: TimeInterval) {
            guard let epoch = lock.withLock({ self.epoch }) else { return }
            onFrames?([Float](repeating: value, count: frames), time, epoch)
        }
    }

    static let headsetUID = "58-18-62-21-1C-6A:input"
    static let route = CaptureRouteProbe(eligibility: { (.bluetooth, true) }, defaultInput: { 77 },
                                         uid: { _ in headsetUID }, defaultInputName: { "WH-1000XM6" })

    static func recorder(_ name: String, _ log: Log, broker: CaptureLeaseBroker,
                         headset: FakeHeadset? = nil) -> (AudioRecorder, FakeBuiltin, FakeHeadset) {
        let builtin = FakeBuiltin("\(name).builtin", log)
        let headset = headset ?? FakeHeadset("\(name).headset", log)
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .auhal,
                                     broker: broker, route: route)
        return (recorder, builtin, headset)
    }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = now() + timeout
        while now() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: L1 — "old release completes after new request" (⌥⌥ ends, ⌘⌘ asks at once)

    @Test func oldReleaseCompletesAfterNewRequestTheNewOwnerWaitsForTheHardware() async throws {
        let log = Log()
        let broker = CaptureLeaseBroker()
        let (dictation, _, slowHeadset) = Self.recorder("A", log, broker: broker)
        let (conversation, _, _) = Self.recorder("B", log, broker: broker)
        conversation.kind = .conversation
        slowHeadset.stopGate = DispatchSemaphore(value: 0)
        try await dictation.startAsync(device: .default)
        dictation.resetCapture()
        _ = dictation.stop()                                      // returns at once; A's headset teardown is slow
        #expect(await Self.waitUntil { log.index(of: "A.headset.stop.begin") != nil })
        let request = Task { try await conversation.startAsync(device: .default) }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!log.all.contains { $0.hasPrefix("B.") })          // nothing of B's hardware starts on top of A's
        slowHeadset.stopGate?.signal()
        try await request.value
        let all = log.all
        guard let released = all.firstIndex(of: "A.headset.stop.end"),
              let started = all.firstIndex(where: { $0.hasPrefix("B.headset.start") }) else {
            Issue.record("log: \(all)"); return
        }
        #expect(released < started)
        #expect((conversation.currentLease?.waitedMs ?? 0) >= 150)
        #expect(await dictation.awaitRelease() == .released)
        _ = conversation.stop()
        #expect(await conversation.awaitRelease() == .released)
    }

    @Test func alternatingOptionOptionCommandCommandAdmitsOneOwner() async throws {
        let log = Log()
        let broker = CaptureLeaseBroker()
        let (dictation, _, _) = Self.recorder("A", log, broker: broker)
        let (conversation, _, _) = Self.recorder("B", log, broker: broker)
        conversation.kind = .conversation
        try await dictation.startAsync(device: .default)
        await #expect(throws: CaptureLeaseBroker.Refusal.busy(holder: .dictation)) {
            try await conversation.startAsync(device: .default)
        }
        #expect(!log.all.contains { $0.hasPrefix("B.") })
        _ = dictation.stop()
        try await conversation.startAsync(device: .default)        // admitted after A's acknowledged release
        await #expect(throws: CaptureLeaseBroker.Refusal.busy(holder: .conversation)) {
            try await dictation.startAsync(device: .default)
        }
        #expect(broker.granted == 2)
        _ = conversation.stop()
        #expect(await conversation.awaitRelease() == .released)
    }

    // MARK: L1 — per-callback lease identity and continuity across the handover

    @Test func aLateCallbackOfTheOldSessionNeverReachesTheNewOneAndContinuityHolds() async throws {
        let log = Log()
        let broker = CaptureLeaseBroker()
        let (recorder, builtin, _) = Self.recorder("A", log, broker: broker)
        try await recorder.startAsync(device: .default)
        recorder.resetCapture()
        var t = Self.now()
        for _ in 0..<5 { builtin.deliver(0.25, at: t, session: 0); t += 0.1 }
        let first = recorder.stop()
        #expect(first.count == 5 * 2_400 && first.allSatisfy { $0 == 0.25 })
        #expect(await recorder.awaitRelease() == .released)
        try await recorder.startAsync(device: .default)            // the next ⌥⌥ (or a host's ⌘⌘)
        recorder.resetCapture()
        t = Self.now()
        builtin.deliver(0.5, at: t, session: 0)                     // session 1's unit callback, late
        for _ in 0..<5 { builtin.deliver(0.75, at: t, session: 1); t += 0.1 }
        let second = recorder.stop()
        #expect(second.count == 5 * 2_400 && second.allSatisfy { $0 == 0.75 })
        #expect(recorder.stats.captureIntervals == "0-500")         // continuous from the boundary
        #expect(recorder.stats.carrier == "builtin:0-\(recorder.stats.recordingMs)" && recorder.stats.carrierFrames == "carrier_frames=builtin:0-500")
        #expect(recorder.stats.lease == "lease=2 lease_kind=dictation lease_wait_ms=0")
    }

    // MARK: L3 — the AUHAL arm, instrumented like the engine arm

    @Test func auhalArmTakesOverAndIsInstrumented() async throws {
        let log = Log()
        let broker = CaptureLeaseBroker()
        let (recorder, builtin, headset) = Self.recorder("A", log, broker: broker)
        let firstBuffer = Log()
        recorder.onFirstBuffer = { firstBuffer.append("first") }
        try await recorder.startAsync(device: .default)
        #expect(log.all.contains("A.headset.start uid=\(Self.headsetUID)"))
        recorder.resetCapture()
        var t = Self.now()
        for step in 0..<10 {
            builtin.deliver(0.25, at: t, session: 0)
            if step >= 3 { headset.deliver(0.1, at: t) }           // signal from 300 ms: takeover after 150 ms
            t += 0.1
        }
        #expect(await Self.waitUntil { firstBuffer.all == ["first"] })     // the lifecycle's watchdog hears it
        _ = recorder.stop()
        #expect(recorder.stats.firstBufferMs != nil)
        let line = recorder.stats.instrumentation
        #expect(line.hasPrefix("headset_backend=auhal route_uid=\(Self.headsetUID) fmt_epochs=1:16000Hz/1ch@"))
        #expect(line.contains(" io_callbacks=builtin:10,headset:7 frames=builtin:24000,headset:16800 zeros=builtin:0,headset:0"))
        #expect(line.contains(" takeover_ms="))
        #expect(!line.contains("takeover_ms=-"))
        #expect(recorder.stats.carrier.hasPrefix("builtin:0-"))
        #expect(recorder.stats.carrier.contains(",headset:"))
        #expect(recorder.stats.startFormat == "16000Hz/1ch")
        #expect(await recorder.awaitRelease() == .released)
    }

    // MARK: L2 — a stopped client is observed and owed exactly one re-attach

    @Test func aStoppedAuhalClientGetsItsObligationReattach() async throws {
        let log = Log()
        let broker = CaptureLeaseBroker()
        let (recorder, builtin, headset) = Self.recorder("A", log, broker: broker)
        try await recorder.startAsync(device: .default)
        recorder.resetCapture()
        let t = Self.now()
        builtin.deliver(0.25, at: t, session: 0)
        headset.ioStops()                                          // the OS stopped IO; no event, no frames
        #expect(await Self.waitUntil { log.all.filter { $0.hasPrefix("A.headset.start") }.count == 2 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(log.all.filter { $0.hasPrefix("A.headset.start") }.count == 2)   // once, not a spin
        _ = recorder.stop()
        #expect(recorder.stats.ioHeld.contains("io_obligations=1/") && recorder.stats.ioHeld.hasSuffix("reattaches=1"))
        #expect(recorder.stats.ioOps.contains(" framework:1"))
    }
}
