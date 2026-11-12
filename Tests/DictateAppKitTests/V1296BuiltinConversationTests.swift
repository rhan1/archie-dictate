import AVFoundation
import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// All capture units and device facts are injected. A private real lease broker owns every session.
@Suite("V1296BuiltinConversation", .serialized)
struct V1296BuiltinConversationTests {
    final class Box<T>: @unchecked Sendable {
        let lock = NSLock()
        private var storage: T
        init(_ value: T) { storage = value }
        var value: T { get { lock.withLock { storage } } set { lock.withLock { storage = newValue } } }
        func update(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
    }
    final class Builtin: BuiltinFormatChangeReporting, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onDeviceLost: ((CaptureEpoch) -> Void)?
        var onFormatChange: ((CaptureEpoch) -> Void)?
        let running = Box<CaptureEpoch?>(nil)
        let readback = Box<UInt32?>(81)
        let starts = Box(0)
        let stops = Box(0)
        var startGate: DispatchSemaphore?
        var stopGate: DispatchSemaphore?
        var afterStart: (() -> Void)?
        var hardwareFormatSummary: (sampleRate: Double, channels: Int)? = (48_000, 1)
        var expectedDeviceID: UInt32? { 81 }
        var currentDeviceID: UInt32? { readback.value }
        var started: Bool { running.value != nil }
        var isDelivering: Bool { started }
        var lastBufferTime: TimeInterval? { nil }
        let backend = "auhal"
        func start(epoch: CaptureEpoch) throws {
            starts.update { $0 += 1 }
            startGate?.wait()
            running.value = epoch
            afterStart?()
        }
        func stop() { stops.update { $0 += 1 }; stopGate?.wait(); running.value = nil }
        func stop(epoch: CaptureEpoch) { if running.value === epoch { stop() } }
        func emit(_ frames: [Float], at time: TimeInterval) {
            if let epoch = running.value { onFrames?(frames, time, epoch) }
        }
    }
    final class Headset: HeadsetCapture {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)?
        var starts = 0
        var isRunning = false
        var lastCallbackTime: TimeInterval? { nil }
        var formatGeneration: Int { 1 }
        var counters: SourceCounters { SourceCounters() }
        let backend = "auhal"
        func start(deviceUID: String, epoch: CaptureEpoch) throws { starts += 1; isRunning = true }
        func stop() { isRunning = false }
        func stop(epoch: CaptureEpoch) { stop() }
    }
    final class Rig: @unchecked Sendable {
        let clock = Box<TimeInterval>(100)
        let units = Box<[Builtin]>([])
        let supplied: [Builtin]
        let headset = Headset()
        let broker = CaptureLeaseBroker()
        let recorder: AudioRecorder
        let failures = Box<[CaptureFailure]>([])
        let verdicts = Box<[BuiltinFirstAudioVerdict]>([])
        let states = Box<[ConversationCaptureState]>([])
        let chunks = Box<[[Int16]]>([])
        let routeFacts = Box((
            RouteFingerprint.RawDeviceFacts(id: 81, uid: "mac", inputChannels: 1),
            RouteFingerprint.RawDeviceFacts(id: 77, uid: "xm-out", outputChannels: 2),
            RouteFingerprint.RawDeviceFacts(id: 78, uid: "xm-in", inputChannels: 1)))
        init(_ supplied: [Builtin] = [], device: MicChoice = .builtIn, kind: CaptureKind = .conversation) {
            self.supplied = supplied
            let units = units, facts = routeFacts
            var probe = CaptureRouteProbe(eligibility: { (.bluetooth, true) }, defaultInput: { 78 },
                uid: { "fake-\($0)" }, defaultInputName: { "fake" })
            probe.builtinConversationRoute = {
                let f = facts.value
                return RouteFingerprint.builtinConversation(rawBuiltin: f.0, rawOutput: f.1, rawInput: f.2)
            }
            probe.effectiveRoute = { "legacy:\(facts.value)" }
            recorder = AudioRecorder(builtin: {
                let index = units.value.count
                let unit = index < supplied.count ? supplied[index] : Builtin()
                units.update { $0.append(unit) }
                return unit
            }, headset: { [headset] in headset }, backend: .auhal, broker: broker, route: probe)
            recorder.kind = kind
            recorder.builtinConversationAutomaticTimers = false
            recorder.builtinConversationClock = { [clock] in clock.value }
            recorder.onCaptureFailure = { [failures] failure in failures.update { $0.append(failure) } }
            recorder.onBuiltinFirstAudio = { [verdicts] verdict in verdicts.update { $0.append(verdict) } }
            recorder.onConversationCaptureState = { [states] state in states.update { $0.append(state) } }
            recorder.onPCMChunk = { [chunks] frames in chunks.update { $0.append(frames) } }
        }
        func start(device: MicChoice = .builtIn) async throws {
            try await recorder.startAsync(device: device)
            recorder.resetCapture()
        }
        func emit(_ value: Float = 0.1, at time: Double? = nil) {
            if let time { clock.value = time }
            units.value.last!.emit(Array(repeating: value, count: 2_400), at: clock.value)
        }
        func tick(_ time: Double) { clock.value = time; recorder.builtinConversationTick(at: time) }
        func stop() async {
            _ = recorder.stop()
            #expect(await recorder.awaitRelease() == .released)
        }
    }
    static var phase: String { ProcessInfo.processInfo.environment["D_V1296_RED"] == "1" ? "RED" : "GREEN" }
    static func eventually(_ check: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if check() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return check()
    }

    @Test func builtin_conversation_creates_engine() async throws {
        let r = Rig(); try await r.start()
        #expect(!r.recorder.hasAllocatedEngine)
        #expect(r.headset.starts == 0)
        #expect(r.units.value[0].starts.value == 1)
        #expect(r.recorder.currentLease != nil)
        print("D \(Self.phase) builtin_conversation_creates_engine=\(r.recorder.hasAllocatedEngine ? 1 : 0)")
        await r.stop()
    }
    @Test func builtin_conversation_registers_no_engine_observer() async throws {
        let r = Rig(); try await r.start()
        #expect(!r.recorder.hasConfigurationObserver)
        print("D GREEN builtin_conversation_registers_no_engine_observer=1")
        await r.stop()
    }
    @Test func d1a_first_buffer_running_and_pipeline() async throws {
        let r = Rig()
        let first = Box(0), levels = Box(0)
        r.recorder.onFirstBuffer = { first.update { $0 += 1 } }
        r.recorder.onLevel = { _ in levels.update { $0 += 1 } }
        try await r.start()
        #expect(r.recorder.isRunning)
        r.emit(); r.emit(at: 100.1)
        #expect(await Self.eventually { first.value == 1 })
        #expect(r.recorder.stats.firstBufferMs != nil)
        #expect(r.chunks.value.count == 2)
        #expect(r.chunks.value.allSatisfy { $0.count == 2_400 && $0.contains { $0 != 0 } })
        #expect(await Self.eventually { levels.value > 0 })
        await r.stop()
        #expect(r.recorder.stats.instrumentation.contains("io_callbacks=builtin:2,headset:0"))
        #expect(r.recorder.stats.carrierFrames.contains("builtin:"))
        print("D GREEN d1a_first_buffer_running_and_pipeline=1")
    }
    @Test(arguments: ["stale", "drift", "lost", "format"])
    func d1a_restart_once_then_fail(reason: String) async throws {
        let r = Rig(); try await r.start(); r.emit()
        let old = r.units.value[0]
        switch reason {
        case "stale": r.tick(100 + CaptureHealth.staleAfter + 0.01)
        case "drift": old.readback.value = 999; r.tick(100.1)
        case "lost": old.onDeviceLost?(old.running.value!)
        default: old.onFormatChange?(old.running.value!)
        }
        #expect(await Self.eventually { r.units.value.count == 2 && r.units.value.last!.started })
        #expect(old.stops.value == 1)
        #expect(r.recorder.builtinConversationDiagnostics.contains("builtin_restart=1 reason=\(reason)"))
        let new = r.units.value.last!
        r.emit(at: 101)
        switch reason {
        case "stale": r.tick(101 + CaptureHealth.staleAfter + 0.01)
        case "drift": new.readback.value = 999; r.tick(101.1)
        case "lost": new.onDeviceLost?(new.running.value!)
        default: new.onFormatChange?(new.running.value!)
        }
        #expect(await Self.eventually { r.failures.value.map(\.reason) == [.builtinBindFailed] })
        #expect(r.units.value.count == 2)
        #expect(!r.recorder.isRunning)
        print("D GREEN d1a_restart_once_then_fail reason=\(reason)=1")
        await r.stop()
    }
    @Test func d1a_apply_fresh_health_and_voice_processing_off() async throws {
        let r = Rig(); try await r.start(); r.emit()
        let old = r.units.value[0]
        r.clock.value = 110
        r.routeFacts.update { $0.1.id = 79 }
        r.recorder.observeConversationRoute()
        #expect(try r.recorder.reconfigureConversationInput(at: 110))
        #expect(old.stops.value == 1)
        #expect(r.units.value.count == 2)
        r.tick(110.01)
        #expect(r.failures.value.isEmpty)
        #expect(!r.recorder.builtinConversationDiagnostics.contains("builtin_restart=1 reason=stale"))
        #expect(r.states.value.last == .routeSettled(generation: 1, voiceProcessing: "off"))
        r.emit(at: 110.02)
        #expect(r.chunks.value.count >= 2)
        print("D GREEN d1a_apply_fresh_health_and_voice_processing_off=1")
        await r.stop()
    }
    @Test func d1a_non_bluetooth_deadline() async throws {
        let r = Rig(); try await r.start()
        for step in 0...20 { r.emit(0, at: 100 + Double(step) / 10) }
        r.tick(102)
        #expect(await Self.eventually { r.failures.value.count == 1 })
        #expect(r.failures.value.first?.reason == .micDead)
        #expect(r.failures.value.first?.durationSeconds == CaptureHealth.failAfter)
        print("D GREEN d1a_non_bluetooth_deadline=2.0")
        await r.stop()
    }

    @Test func engine_stopped_unchanged_fp_raises_generation() async throws {
        let r = Rig(); try await r.start()
        for _ in 0..<18 { r.recorder.observeConversationRoute(invalidated: true) }
        #expect(r.recorder.activeRouteGeneration == 0)
        #expect(r.states.value.isEmpty)
        print("D \(Self.phase) engine_stopped_unchanged_fp_raises_generation=\(r.recorder.activeRouteGeneration)")
        await r.stop()
    }
    @Test func builtin_conversation_route_loop() async throws {
        let r = Rig(); try await r.start(); r.emit()
        // Eighteen notifications over five virtual seconds, from the production field projector.
        for step in 0..<18 {
            r.clock.value = 100 + Double(step) * 0.25
            r.routeFacts.update {
                $0.1.rate = step.isMultiple(of: 2) ? 16_000 : 48_000
                $0.1.outputChannels = UInt32(step + 1)
                $0.2.rate = Double(16_000 + step)
                $0.2.inputChannels = UInt32(step + 1)
                $0.2.alive.toggle()
            }
            r.recorder.observeConversationRoute(invalidated: true)
        }
        #expect(r.recorder.activeRouteGeneration == 0)
        #expect(r.units.value.count == 1 && r.units.value[0].stops.value == 0)
        #expect(!r.recorder.builtinConversationDiagnostics.contains { $0.hasPrefix("conv_apply=") })
        // Every required field still invalidates the real recorder, including a fractional rate.
        for field in 0..<3 {
            r.routeFacts.update {
                if field == 0 { $0.0.rate += 0.125 }
                if field == 1 { $0.1.uid += " changed ||\n" }
                if field == 2 { $0.2.id += 1 }
            }
            r.recorder.observeConversationRoute()
            #expect(r.recorder.activeRouteGeneration == UInt64(field + 1))
            #expect(try r.recorder.reconfigureConversationInput(at: r.clock.value))
        }
        print("D \(Self.phase) builtin_conversation_route_loop=1")
        await r.stop()
    }
    @Test func headset_toggle_converges_within_2_generations() async throws {
        let r = Rig(); try await r.start()
        for step in 0..<2 {
            r.routeFacts.update {
                if step == 0 { $0.1.alive = false; $0.2.alive = false }
                else { $0.1.id = 90; $0.1.uid = "speakers"; $0.2.id = 81; $0.2.uid = "mac" }
            }
            r.clock.value = 100 + Double(step) * 0.5
            r.recorder.observeConversationRoute()
            #expect(try r.recorder.reconfigureConversationInput(at: r.clock.value))
        }
        #expect(r.recorder.activeRouteGeneration == 2)
        #expect(r.recorder.activeAppliedRouteGeneration == 2)
        #expect(r.clock.value - 100 < 2)
        print("D GREEN headset_toggle_converges_within_2_generations=1")
        await r.stop()
    }
    @Test func builtin_bind_drift_runs_silent() async throws {
        let r = Rig(); try await r.start(); r.emit()
        let old = r.units.value[0]
        old.readback.value = 999
        let began = ProcessInfo.processInfo.systemUptime
        r.tick(100.1)
        old.emit(Array(repeating: 0, count: 2_400), at: 100.1)
        #expect(await Self.eventually { r.units.value.count == 2 || !r.failures.value.isEmpty })
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        #expect(elapsed <= AudioRecorder.builtinBindFailureLimit)
        #expect(r.units.value.count == 2 || r.failures.value.first?.reason == .builtinBindFailed)
        #expect(!(r.recorder.isRunning && r.units.value.count == 1 && r.failures.value.isEmpty))
        print("D \(Self.phase) builtin_bind_drift_runs_silent=\(r.units.value.count == 1 && r.failures.value.isEmpty ? 1 : 0)")
        await r.stop()
    }
    @Test func bind_failed_does_not_wait_on_teardown() async throws {
        let old = Builtin(), next = Builtin()
        let gate = DispatchSemaphore(value: 0)
        old.stopGate = gate
        let r = Rig([old, next]); try await r.start(); r.emit()
        let savedFrames = old.onFrames!, savedEpoch = old.running.value!
        old.readback.value = nil
        let began = ProcessInfo.processInfo.systemUptime
        r.tick(100.1)
        let count = r.chunks.value.count
        old.emit(Array(repeating: 0, count: 2_400), at: 100.2)
        #expect(r.chunks.value.count == count)
        #expect(await Self.eventually { !r.failures.value.isEmpty })
        #expect(ProcessInfo.processInfo.systemUptime - began <= AudioRecorder.builtinBindFailureLimit)
        #expect(r.failures.value.map(\.reason) == [.builtinBindFailed])
        #expect(next.starts.value == 0) // old native stop is hung: replacement must never open
        savedFrames(Array(repeating: 0.5, count: 2_400), 100.3, savedEpoch)
        #expect(!r.recorder.isRunning && r.chunks.value.count == count)
        print("D GREEN bind_failed_does_not_wait_on_teardown=1")
        gate.signal()
        await r.stop()
    }
    @Test func unverified_rebind_failure_and_attempt_fence() async throws {
        let first = Builtin(), second = Builtin()
        second.readback.value = nil
        let r = Rig([first, second]); try await r.start(); r.emit()
        first.readback.value = nil
        r.tick(100.1)
        #expect(await Self.eventually { r.failures.value.count == 1 })
        #expect(r.failures.value.first?.reason == .builtinBindFailed)
        #expect(r.units.value.count == 2)
        let count = r.chunks.value.count
        second.readback.value = 81
        second.emit(Array(repeating: 0.5, count: 2_400), at: 100.2)
        #expect(r.chunks.value.count == count)
        print("D GREEN unverified_rebind_failure_and_attempt_fence=1")
        await r.stop()
    }

}
