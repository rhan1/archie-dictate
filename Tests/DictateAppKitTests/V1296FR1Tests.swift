import Foundation
import OSLog
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

    // MARK: V-F16 — stop() leaves a reusable recorder on the default input

    @Test func stop_resets_selected_device() async throws {
        let r = Rig(); try await r.start()
        #expect(r.recorder.activeInputChoice == .builtIn)
        await r.stop()
        let reset = r.recorder.activeInputChoice == .default
        #expect(reset)
        // The same recorder's next `.default` conversation takes the legacy branch from its first call.
        r.clock.value = ProcessInfo.processInfo.systemUptime
        try await r.start(device: .default)
        r.emit(at: ProcessInfo.processInfo.systemUptime)
        #expect(r.headset.starts == 1 && r.recorder.isRunning)
        #expect(r.routeWatches.value == ["builtin", "legacy"])
        print("D GREEN stop_resets_selected_device=\(reset ? 1 : 0)")
        await r.stop()
    }

    // MARK: U4 — the D5 seam is conversation-only, expires, and malformed values are deleted

    static let key = BuiltinCaptureUnit.uidOverrideDefaultsKey
    static func suite() -> (UserDefaults, String) {
        let name = "fr1-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
    static var epoch: Int { Int(Date().timeIntervalSince1970) }
    /// A real BuiltinCaptureUnit on a scratch suite; only CoreAudio's two lookups are injected.
    static func unit(_ defaults: UserDefaults, lookups: V.Box<[String]>, notes: V.Box<[String]>) -> BuiltinCaptureUnit {
        let unit = BuiltinCaptureUnit(defaults: defaults, lookupUID: { uid in
            lookups.update { $0.append(uid) }; return uid == "override-uid" ? 92 : nil
        }, builtIn: { 81 })
        unit.note = { line in notes.update { $0.append(line) } }
        return unit
    }

    @Test func override_rebinds_dictation() throws {
        let (defaults, name) = Self.suite(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("override-uid|\(Self.epoch + 300)", forKey: Self.key)
        let lookups = V.Box<[String]>([]), notes = V.Box<[String]>([])
        let unit = Self.unit(defaults, lookups: lookups, notes: notes)
        // A dictation start (the bridge arm) never marks the unit: start(epoch:)'s resolution, minus the AUHAL.
        let dictation = try unit.resolveStartDevice()
        #expect(dictation.id == 81 && dictation.overrideUID == nil)
        #expect(lookups.value.isEmpty && notes.value.isEmpty)
        #expect(defaults.string(forKey: Self.key) != nil) // dictation does not even read (or delete) the key
        // Control: the conversation mark on the same unit honours the live value once.
        unit.allowConversationSeamForNextStart()
        let conversation = try unit.resolveStartDevice()
        #expect(conversation.id == 92 && notes.value == ["builtin_override=1 uid=override-uid"])
        let again = try unit.resolveStartDevice() // the mark is per start
        #expect(again.id == 81)
        print("D GREEN override_rebinds_dictation=\(dictation.id == 92 ? 1 : 0) dictation_id=\(dictation.id) conversation_id=\(conversation.id) next_unmarked_id=\(again.id)")
    }

    @Test func override_never_expires() throws {
        let (defaults, name) = Self.suite(); defer { defaults.removePersistentDomain(forName: name) }
        let lookups = V.Box<[String]>([]), notes = V.Box<[String]>([])
        let unit = Self.unit(defaults, lookups: lookups, notes: notes)
        let expiry = Self.epoch + 300
        let value = "override-uid|\(expiry)"
        func at(_ t: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }
        defaults.set(value, forKey: Self.key)
        unit.allowConversationSeamForNextStart()
        #expect(try unit.resolveStartDevice(now: at(expiry - 300)).id == 92) // honoured while live
        // The harness was killed and never removed it: at expiry (and later) it is ignored and deleted.
        unit.allowConversationSeamForNextStart()
        #expect(try unit.resolveStartDevice(now: at(expiry)).id == 81)
        #expect(defaults.object(forKey: Self.key) == nil)
        defaults.set(value, forKey: Self.key)
        unit.allowConversationSeamForNextStart()
        let later = try unit.resolveStartDevice(now: at(expiry + 3_600))
        let left = defaults.object(forKey: Self.key) != nil
        #expect(later.id == 81 && !left)
        #expect(notes.value == ["builtin_override=1 uid=override-uid"]) // ignored values log nothing
        print("D GREEN override_never_expires honoured_after_expiry=\(later.id == 92 ? 1 : 0) key_left=\(left ? 1 : 0)")
    }

    @Test func override_malformed_deleted() throws {
        let lookups = V.Box<[String]>([]), notes = V.Box<[String]>([])
        let now = Self.epoch
        let values: [(String, Any)] = [
            ("not_string", 42), ("bare_uid", "override-uid"), ("empty", ""), ("no_expiry", "override-uid|"),
            ("text_expiry", "override-uid|soon"), ("empty_uid", "|\(now + 300)"), ("too_far", "override-uid|\(now + 901)"),
            ("infinite", "override-uid|inf"), ("expired", "override-uid|\(now - 1)")]
        var deleted = 0
        for (_, value) in values {
            let (defaults, name) = Self.suite(); defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(value, forKey: Self.key)
            let unit = Self.unit(defaults, lookups: lookups, notes: notes)
            unit.allowConversationSeamForNextStart()
            let resolved = try unit.resolveStartDevice()
            #expect(resolved.id == 81 && resolved.overrideUID == nil)
            if defaults.object(forKey: Self.key) == nil { deleted += 1 }
        }
        #expect(deleted == values.count)
        #expect(lookups.value.isEmpty && notes.value.isEmpty)
        // Boundary control: expiry = now + 900 is still live.
        let (defaults, name) = Self.suite(); defer { defaults.removePersistentDomain(forName: name) }
        let at = Date(timeIntervalSince1970: TimeInterval(now))
        defaults.set("override-uid|\(now + 900)", forKey: Self.key)
        let unit = Self.unit(defaults, lookups: lookups, notes: notes)
        unit.allowConversationSeamForNextStart()
        #expect(try unit.resolveStartDevice(now: at).id == 92)
        print("D GREEN override_malformed_deleted=\(deleted == values.count ? 1 : 0) cases=\(values.count) deleted=\(deleted) boundary_900_live=1")
    }

    /// V-G5: the default log wiring (the unit's own `note` = AppController.note, plus its unified-log line) puts
    /// `builtin_override=1 uid=<uid>` in this process's unified log. No closure captures the line.
    @Test func override_line_reaches_unified_log() async throws {
        let (defaults, name) = Self.suite(); defer { defaults.removePersistentDomain(forName: name) }
        let uid = "fr1-\(UUID().uuidString)"
        let expiredUID = "fr1-expired-\(UUID().uuidString)"
        defaults.set("\(uid)|\(Self.epoch + 300)", forKey: Self.key)
        let unit = BuiltinCaptureUnit(defaults: defaults, lookupUID: { $0 == uid ? 92 : nil }, builtIn: { 81 })
        let began = Date().addingTimeInterval(-1)
        unit.allowConversationSeamForNextStart()
        #expect(try unit.resolveStartDevice().id == 92)
        defaults.set("\(expiredUID)|\(Self.epoch - 5)", forKey: Self.key) // negative control: never logged
        unit.allowConversationSeamForNextStart()
        #expect(try unit.resolveStartDevice().id == 81)
        func entries(_ text: String) throws -> [OSLogEntryLog] {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            return try store.getEntries(at: store.position(date: began))
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.composedMessage.contains(text) }
        }
        var found: [OSLogEntryLog] = []
        for _ in 0..<60 {
            found = try entries("builtin_override=1 uid=\(uid)")
            if !found.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let control = try entries(expiredUID).count
        #expect(found.count == 1)
        #expect(control == 0)
        print("D GREEN override_unified_log=\(found.count == 1 ? 1 : 0) entries=\(found.count) subsystem=\(found.first?.subsystem ?? "none") level=\(found.first.map { String($0.level.rawValue) } ?? "-") expired_control_entries=\(control)")
    }

    // MARK: V-G1 — a dictation start with the seam set binds the real built-in (recorder wiring + production resolution)

    @Test func dictation_ignores_override() async throws {
        let (defaults, name) = Self.suite(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("override-uid|\(Self.epoch + 300)", forKey: Self.key)
        let lookups = V.Box<[String]>([])
        func fake() -> Builtin {
            let unit = Builtin()
            unit.resolve = { mark in
                try BuiltinCaptureUnit.resolveDevice(defaults: defaults, conversation: mark, lookupUID: { uid in
                    lookups.update { $0.append(uid) }; return uid == "override-uid" ? 92 : nil
                }, builtIn: { 81 }, note: { _ in }).id
            }
            return unit
        }
        let dictationUnit = fake()
        let d = Rig([dictationUnit], kind: .dictation); d.clock.value = ProcessInfo.processInfo.systemUptime
        try await d.start(device: .default)
        d.emit(at: ProcessInfo.processInfo.systemUptime)
        #expect(dictationUnit.starts.value == 1 && d.chunks.value.count == 1) // the bridge's built-in arm ran
        #expect(dictationUnit.seamMarks.value == [false])
        #expect(dictationUnit.resolved.value == [81])
        #expect(lookups.value.isEmpty && defaults.object(forKey: Self.key) != nil)
        await d.stop()
        // Control: a sole built-in conversation start on the same key is marked and honours it.
        let conversationUnit = fake()
        let c = Rig([conversationUnit]); try await c.start()
        #expect(conversationUnit.seamMarks.value == [true] && conversationUnit.resolved.value == [92])
        await c.stop()
        print("D GREEN dictation_ignores_override=\(dictationUnit.resolved.value == [81] ? 1 : 0) dictation_bound=\(dictationUnit.resolved.value.first ?? 0) dictation_marked=\(dictationUnit.seamMarks.value.first == true ? 1 : 0) conversation_bound=\(conversationUnit.resolved.value.first ?? 0)")
    }
}
