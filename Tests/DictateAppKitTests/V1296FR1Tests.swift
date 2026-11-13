import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// archie-v73-fr1 (Lane D): U2, V-F16, U4, U7, U8, real timers, dictation controls.
/// Same hardware-free rig as V1296BuiltinConversation: injected units, a private real lease broker.
@Suite("V1296FR1", .serialized)
struct V1296FR1Tests {
    typealias V = V1296BuiltinConversationTests
    typealias Rig = V1296BuiltinConversationTests.Rig
    typealias Builtin = V1296BuiltinConversationTests.Builtin
    struct StartFailed: Error {}

    // MARK: U2 — a bind failure inside a route apply reaches the host as a typed throw

    @Test(arguments: ["start_throws", "format_twice", "stop_held"])
    func apply_bind_failure_is_thrown_typed(_ c: String) async throws {
        let first = Builtin(), second = Builtin()
        let gate = DispatchSemaphore(value: 0)
        if c == "start_throws" { second.startError = StartFailed() }
        if c == "stop_held" { first.stopGate = gate }
        let r = Rig([first, second]); try await r.start(); r.emit()
        if c == "format_twice" {
            r.clock.value = 100.6
            first.onFormatChange?(first.running.value!)
            #expect(await V.eventually { r.recorder.activeRouteGeneration == 1 })
            #expect(try await r.recorder.applyPendingConversationDeviceChange())
            #expect(await V.eventually { r.verifiedStart(2) })
            r.clock.value = 101.6 // second format change 1 s later, inside the 5 s window
            second.onFormatChange?(second.running.value!)
            #expect(await V.eventually { r.recorder.activeRouteGeneration == 2 })
        } else {
            r.routeFacts.update { $0.1.id = 90 }
            r.recorder.observeConversationRoute()
            #expect(r.recorder.activeRouteGeneration == 1)
        }
        var thrown: CaptureFailure?
        var other: Error?
        do { _ = try await r.recorder.applyPendingConversationDeviceChange() }
        catch AudioRecorder.RecorderError.builtinBindFailed(let failure) { thrown = failure }
        catch { other = error }
        try? await Task.sleep(nanoseconds: 100_000_000) // any asynchronous callback would have landed
        #expect(other == nil)
        #expect(thrown?.reason == .builtinBindFailed)
        #expect(r.failures.value.isEmpty)
        #expect(!r.recorder.isRunning)
        print("D GREEN apply_bind_failure_typed case=\(c) thrown=\(thrown?.reason.rawValue ?? "none") callbacks=\(r.failures.value.count)")
        gate.signal(); gate.signal(); gate.signal()
        await r.stop()
    }

    /// Outside an apply the failure is still delivered once, asynchronously, to onCaptureFailure.
    @Test func bind_failure_outside_apply_still_calls_back_once() async throws {
        let first = Builtin(); first.readback.value = 999
        let second = Builtin(); second.readback.value = 999
        let r = Rig([first, second]); try await r.start()
        #expect(await V.eventually { r.units.value.count == 2 })
        r.tick(100.2)
        #expect(await V.eventually { r.failures.value.map(\.reason) == [.builtinBindFailed] })
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(r.failures.value.count == 1)
        print("D GREEN bind_failure_outside_apply_callbacks=\(r.failures.value.count)")
        await r.stop()
    }
}
