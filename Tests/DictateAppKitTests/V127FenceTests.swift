import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.27 FIX ROUND 1 (Astra BLOCKERs 2/3, MINOR 5; Fable MAJOR 1/2): a built-in that B1 replaced (A, retired)
/// must never reach its replacement (B) — neither late frames nor a late device-lost — and the lease's built-in
/// release must wait for A's teardown too. Real `AudioRecorder`, fake units, real health clock, no hardware.
/// A reads back another device as soon as it starts (a genuine drift) while the headset's start is in flight,
/// so B1 rule 3 replaces it with B once.
@Suite("V127Fence", .serialized)
struct V127FenceTests {
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T { lock.withLock { value } }
        func set(_ v: T) { lock.withLock { value = v } }
        func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
    }

    final class FenceBuiltin: BuiltinCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onDeviceLost: ((CaptureEpoch) -> Void)?
        let device: UInt32
        let stopGate: DispatchSemaphore?
        private let lock = NSLock()
        private var running: CaptureEpoch?
        private var lastEpoch: CaptureEpoch?
        private var timer: DispatchSourceTimer?
        private(set) var starts = 0
        private(set) var stops = 0
        init(device: UInt32, stopGate: DispatchSemaphore? = nil) { self.device = device; self.stopGate = stopGate }
        func start(epoch: CaptureEpoch) throws {
            var made: DispatchSourceTimer?
            if device == 81 {
                let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "v127.fence.builtin"))
                t.schedule(deadline: .now() + 0.01, repeating: 0.01)
                t.setEventHandler { [weak self] in
                    guard let self, let epoch = self.lock.withLock({ self.running }) else { return }
                    self.onFrames?([Float](repeating: 0.1, count: 240), ProcessInfo.processInfo.systemUptime - 0.01, epoch)
                }
                made = t
            }
            lock.withLock { starts += 1; running = epoch; lastEpoch = epoch; timer = made }
            made?.resume()
        }
        func stop() {
            guard lock.withLock({ running != nil }) else { return }
            stopGate?.wait()
            lock.withLock { running = nil; timer?.cancel(); timer = nil; stops += 1 }
        }
        func stop(epoch: CaptureEpoch) { if lock.withLock({ running === epoch }) { stop() } }
        var isDelivering: Bool { lock.withLock { running != nil } }
        var started: Bool { lock.withLock { running != nil } }
        var currentDeviceID: UInt32? { lock.withLock { running != nil ? device : nil } }
        var expectedDeviceID: UInt32? { 81 }
        var lastBufferTime: TimeInterval? { nil }
        let backend = "fake"
        var isRunning: Bool { lock.withLock { running != nil } }
        /// The retired unit's callbacks arriving late (queued before its teardown finished).
        func fireLateFrames(value: Float) {
            guard let epoch = lock.withLock({ lastEpoch }) else { return }
            onFrames?([Float](repeating: value, count: 2_400), ProcessInfo.processInfo.systemUptime - 0.1, epoch)
        }
        func fireLateLost() {
            guard let epoch = lock.withLock({ lastEpoch }) else { return }
            onDeviceLost?(epoch)
        }
    }

    static let route = V127FirstDictationTests.route
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func waitUntil(_ event: String, _ seconds: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = now() + seconds
        while now() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if condition() { return }
        Issue.record("missing event=\(event) after \(Int(seconds))s")
        throw URLError(.timedOut)
    }

    struct Rig {
        let recorder: AudioRecorder
        let a: Box<FenceBuiltin?>
        let b: Box<FenceBuiltin?>
        let headset: V127FirstDictationTests.SlowHeadset
        let pcm: Box<[Int16]>
        let start: Task<Void, Error>
    }

    /// A (drifting, its stop held by `gate`) is replaced by B (healthy) while the headset start is in flight.
    static func rig(gate: DispatchSemaphore?, keepA: Bool = true) async throws -> Rig {
        let a = Box<FenceBuiltin?>(nil), b = Box<FenceBuiltin?>(nil)
        let made = Box(0)
        let weakA = WeakBox()
        let headset = V127FirstDictationTests.SlowHeadset()
        let recorder = AudioRecorder(builtin: {
            made.mutate { $0 += 1 }
            if made.get() == 1 {
                let unit = FenceBuiltin(device: 154, stopGate: gate)
                if keepA { a.set(unit) } else { weakA.value = unit; sharedWeakA.set(weakA) }
                return unit
            }
            let unit = FenceBuiltin(device: 81)
            b.set(unit)
            return unit
        }, headset: { headset }, backend: .auhal, broker: CaptureLeaseBroker(), route: route)
        let pcm = Box<[Int16]>([])
        recorder.onPCMChunk = { chunk in pcm.mutate { $0 += chunk } }
        headset.level = 0                                   // the link delivers zeros: the built-in keeps carrying
        headset.startReturnsAt = now() + 1.0
        let start = Task { try await recorder.startAsync(device: .default) }
        try await Task.sleep(nanoseconds: 30_000_000)
        recorder.resetCapture()
        try await waitUntil("builtin_rebuilt") { (b.get()?.starts ?? 0) >= 1 }
        return Rig(recorder: recorder, a: a, b: b, headset: headset, pcm: pcm, start: start)
    }
    final class WeakBox: @unchecked Sendable { weak var value: FenceBuiltin? }
    static let sharedWeakA = Box<WeakBox?>(nil)

    /// FR1-B: A's late device-lost and late frames after B took over. RED on fa14d35: B is stopped (marked
    /// lost) and A's 0.9 frames enter the dictation.
    @Test func retiredBuiltinCallbacksNeverReachTheReplacement() async throws {
        let gate = DispatchSemaphore(value: 0)
        let rig = try await Self.rig(gate: gate)
        _ = try? await rig.start.value                            // the headset start returned: capture runs
        try await Task.sleep(nanoseconds: 200_000_000)            // B delivers and carries
        let beforeLate = rig.pcm.get().count
        rig.a.get()?.fireLateFrames(value: 0.9)
        try await Task.sleep(nanoseconds: 200_000_000)
        rig.a.get()?.fireLateLost()
        try await Task.sleep(nanoseconds: 400_000_000)            // several health ticks
        let bRunning = rig.b.get()?.isRunning ?? false
        let bStops = rig.b.get()?.stops ?? -1
        _ = rig.recorder.stop()
        let foreign = rig.pcm.get().filter { $0 > 20_000 }.count
        let kept = rig.pcm.get().count
        print("FR1-B LITERAL b_running=\(bRunning ? 1 : 0) b_stops=\(bStops) retired_frames_kept=\(foreign) pcm_before_late=\(beforeLate) pcm_total=\(kept) carrier=\(rig.recorder.stats.carrier)")
        #expect(bRunning && bStops == 0)
        #expect(foreign == 0)
        #expect(beforeLate > 0)
        gate.signal(); gate.signal()
        _ = await rig.recorder.awaitRelease()
    }

    /// FR1-C: the built-in release waits for the retired A's teardown. RED on fa14d35: `released` while A's stop is held.
    @Test func leaseReleaseWaitsForTheRetiredUnitsTeardown() async throws {
        let gate = DispatchSemaphore(value: 0)
        let rig = try await Self.rig(gate: gate)
        _ = try? await rig.start.value                            // the headset part can release at once
        _ = rig.recorder.stop()
        let state = Box<CaptureLease.State?>(nil)
        let waiter = Task { state.set(await rig.recorder.awaitRelease()) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let whileHeld = state.get()
        gate.signal()
        await waiter.value
        print("FR1-C LITERAL held state_while_A_stop_held=\(whileHeld.map { "\($0)" } ?? "releasing") after_A_stop=\(state.get().map { "\($0)" } ?? "none")")
        #expect(whileHeld == nil)
        #expect(state.get() == .released)
        rig.start.cancel()
    }

    /// FR1-C: a retired teardown that never completes falls into the bounded quarantine (never `released`).
    @Test func stuckRetiredTeardownIsQuarantined() async throws {
        let gate = DispatchSemaphore(value: 0)
        let rig = try await Self.rig(gate: gate)
        _ = try? await rig.start.value
        let t0 = Self.now()
        _ = rig.recorder.stop()
        let state = await rig.recorder.awaitRelease()
        let ms = Int((Self.now() - t0) * 1000)
        print("FR1-C LITERAL stuck state=\(state.map { "\($0)" } ?? "none") after_ms=\(ms)")
        #expect(state == .quarantined)
        #expect(ms < 6_000)
        gate.signal(); gate.signal()
        rig.start.cancel()
    }

    /// FR1-E: a stopped, replaced unit is not kept alive by its own callbacks (weak captures).
    @Test func replacedUnitDeallocates() async throws {
        let rig = try await Self.rig(gate: nil, keepA: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = rig.recorder.stop()
        _ = await rig.recorder.awaitRelease()
        rig.start.cancel()
        _ = try? await rig.start.value
        try await Task.sleep(nanoseconds: 200_000_000)
        let alive = Self.sharedWeakA.get()?.value != nil
        print("FR1-E LITERAL unit_deallocated=\(alive ? 0 : 1)")
        #expect(!alive)
    }
}
