import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.19 (ST2): the personal-dictionary learner on the REAL insertion path (C2 typed insertion, fake AX,
/// manual clock) and on the host controller. Temp directories only; no live AX, no network, no audio.
@MainActor @Suite(.serialized)
struct ST2EditLearnerTests {
    /// The fake document: a prefix and a suffix around the dictated span.
    nonisolated static let before = "Meeting notes, Tuesday. The design review agreed that "
    nonisolated static let after = " Next step: ship the build to the team on Friday."
    nonisolated static let dictated = "Polytrace ships the anchor fix today."
    nonisolated static let edited = "Politrace ships the anchor fix today."

    final class Fixture {
        let pb = NSPasteboard(name: .init("dictate-st2-\(UUID().uuidString)"))
        let clock = V15PasteConfirmationTests.ManualMainScheduler()
        let poster = V18TypedInsertionTests.Poster()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("st2-learner-\(UUID().uuidString)")
        var store: KeytermsStore { KeytermsStore(url: root.appendingPathComponent("keyterms.txt")) }
        /// The field the insertion types into (the inserter's fake AX reader).
        var field: String = ST2EditLearnerTests.before + ST2EditLearnerTests.after
        var typed = ""
        var insertLogs: [String] = []
        var learnLogs: [String] = []
        var outcomes: [EditLearner.Outcome] = []
        var result: TextInserter.Result?
        var confirmedAt: TimeInterval = 0
        /// Identity of the element the insertion confirmed against, and of the focused element 20 s later.
        var insertionIdentity: FocusIdentity? = Fixture.identity()
        var focusedIdentity: FocusIdentity? = Fixture.identity()
        /// What the ONE value read returns at observation (nil = unreadable).
        var observedValue: String?
        var valueReads = 0
        let learnerOn: Bool

        static func identity(pid: Int32 = 4242, element: String = "AXTextArea#1",
                             document: String? = "file:///fixture/notes.txt") -> FocusIdentity {
            FocusIdentity(pid: pid, role: "AXTextArea", document: document, element: AnyHashable(element))
        }

        lazy var learner: EditLearner = {
            let learner = EditLearner(store: store, focused: { [unowned self] in
                guard let identity = focusedIdentity else { return nil }
                return FocusSnapshot(identity: identity, readValue: { [unowned self] in
                    valueReads += 1
                    return observedValue
                })
            }, schedule: clock.schedule, log: { [unowned self] in learnLogs.append($0) })
            learner.onOutcome = { [unowned self] in outcomes.append($0) }
            return learner
        }()

        lazy var inserter: TextInserter = {
            let inserter = TextInserter(pasteboard: pb, keyEventPosting: poster, typingEligibility: { .editable },
                targetBundleID: { "dev.warp.Warp-Stable" },
                substitutionPolicy: TextSubstitutionPolicy(reader: { _, _ in nil }),
                schedule: clock.schedule, axReader: { [unowned self] in [field] },
                logger: { [unowned self] in insertLogs.append($0) }, now: { [unowned self] in clock.now },
                focusIdentity: { [unowned self] in insertionIdentity })
            if learnerOn { inserter.onConfirmedReadBack = { [unowned self] in learner.insertionConfirmed($0) } }
            return inserter
        }()

        init(learnerOn: Bool = true) {
            self.learnerOn = learnerOn
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            poster.onEvent = { [unowned self] event in
                guard event.keyDown else { return }
                typed += String(decoding: event.utf16, as: UTF16.self)
                field = ST2EditLearnerTests.before + typed + ST2EditLearnerTests.after
            }
        }
        deinit {
            pb.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }

        /// Dictation inserted by typing and confirmed by the unchanged AX rule.
        func insertConfirmed(_ text: String = ST2EditLearnerTests.dictated) async {
            result = nil
            let queued = clock.items.count
            inserter.insert(text, onResult: { [unowned self] in result = $0; confirmedAt = clock.now })
            for _ in 0..<500 where clock.items.count <= queued {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            clock.advance(to: clock.now + 10.1)
            #expect(result == .confirmed)
        }

        var lines: [String] {
            ((try? String(contentsOf: store.url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        var learned: Int { lines.contains("Politrace") ? 1 : 0 }
    }

    /// The edit made inside the 20-s window, then the virtual 20 s elapse.
    private func editAndWait(_ f: Fixture, value: String? = ST2EditLearnerTests.before + ST2EditLearnerTests.edited
                             + ST2EditLearnerTests.after) {
        f.observedValue = value
        f.clock.advance(to: f.clock.now + EditLearner.delay + 0.5)
    }

    // MARK: - RED / GREEN

    @Test func redLearnerDisabledLearnsNothing() async {
        let f = Fixture()
        f.learner.redMutationDisabled = true   // ST2 RED MUTATION: the learner ignores the confirmation.
        await f.insertConfirmed()
        editAndWait(f)
        let same = f.focusedIdentity == f.insertionIdentity
        print("ST2 RED before=Polytrace after=Politrace same_element=\(same ? 1 : 0) learned=\(f.learned)")
        #expect(same && f.learned == 0)
        #expect(f.learner.observations == 0 && f.valueReads == 0)
    }

    @Test func greenLearnsTheReplacedWordFromTheAnchoredSpan() async {
        let f = Fixture()
        await f.insertConfirmed()
        #expect(f.learner.hasPending)
        // Nothing happens before 20 s (virtual) after the confirmation; exactly at 20 s, one observation.
        f.observedValue = Self.before + Self.edited + Self.after
        f.clock.advance(to: f.confirmedAt + EditLearner.delay - 0.01)
        #expect(f.learner.observations == 0 && f.lines.isEmpty)
        f.clock.advance(to: f.confirmedAt + EditLearner.delay)
        #expect(f.learner.observations == 1)
        editAndWait(f)
        let same = f.focusedIdentity == f.insertionIdentity
        print("ST2 GREEN before=Polytrace after=Politrace same_element=\(same ? 1 : 0) learned=\(f.learned)")
        #expect(same && f.learned == 1)
        #expect(f.lines == ["Politrace"])
        #expect(f.learner.observations == 1 && f.valueReads == 1)
        #expect(f.learnLogs == ["dict_learn added=1"])
        // Counts only: neither the dictation nor the learned word reaches any log.
        #expect(!(f.learnLogs + f.insertLogs).contains { $0.contains("trace") || $0.contains("anchor") })
    }

    // MARK: - CONTROLS

    @Test func sameAppOtherElementOrDocumentLearnsNothing() async {
        // Another field in the SAME app holds the very same edited text: tempting, and must be ignored.
        for focused in [Fixture.identity(element: "AXTextArea#2"), Fixture.identity(document: "file:///fixture/other.txt")] {
            let f = Fixture()
            await f.insertConfirmed()
            f.focusedIdentity = focused
            editAndWait(f)
            let sameApp = focused.pid == f.insertionIdentity?.pid
            let sameElement = focused == f.insertionIdentity
            if focused.document == "file:///fixture/notes.txt" {
                print("ST2 CONTROL same_app=\(sameApp ? 1 : 0) same_element=\(sameElement ? 1 : 0) learned=\(f.learned)")
            }
            #expect(sameApp && !sameElement && f.learned == 0)
            #expect(f.outcomes == [.skipped(.elementChanged)])
            #expect(f.valueReads == 0)   // the other field's text is never read
            #expect(f.learnLogs == ["dict_learn added=0 skip=element_changed"])
        }
        // Another app entirely, and no focus at all.
        let other = Fixture()
        await other.insertConfirmed()
        other.focusedIdentity = Fixture.identity(pid: 999)
        editAndWait(other)
        #expect(other.outcomes == [.skipped(.appChanged)] && other.learned == 0 && other.valueReads == 0)
        let none = Fixture()
        await none.insertConfirmed()
        none.focusedIdentity = nil
        editAndWait(none)
        #expect(none.outcomes == [.skipped(.noFocus)] && none.learned == 0)
    }

    @Test func unlocatableOrAmbiguousSpanLearnsNothing() async {
        // The prefix anchor itself was edited too: the span cannot be located between the SAME anchors.
        let f = Fixture()
        await f.insertConfirmed()
        editAndWait(f, value: Self.before.replacingOccurrences(of: "agreed that ", with: "decided: ")
                    + Self.edited + Self.after)
        let same = f.focusedIdentity == f.insertionIdentity
        let unlocatable = f.outcomes == [.skipped(.spanUnlocatable)]
        print("ST2 CONTROL same_element=\(same ? 1 : 0) inserted_span_unlocatable=\(unlocatable ? 1 : 0) learned=\(f.learned)")
        #expect(same && unlocatable && f.learned == 0)
        // The suffix pasted again elsewhere: the anchor is no longer unique → ambiguous → skip.
        let dup = Fixture()
        await dup.insertConfirmed()
        editAndWait(dup, value: Self.before + Self.edited + Self.after + Self.after)
        #expect(dup.outcomes == [.skipped(.spanUnlocatable)] && dup.learned == 0)
        // The whole field replaced by unrelated text: nothing anchors.
        let gone = Fixture()
        await gone.insertConfirmed()
        editAndWait(gone, value: "Politrace")
        #expect(gone.outcomes == [.skipped(.spanUnlocatable)] && gone.learned == 0)
    }

    @Test func duplicateIsNotAppendedTwice() async throws {
        let f = Fixture()
        await f.insertConfirmed()
        editAndWait(f)
        #expect(f.lines == ["Politrace"])
        // The same correction again in a later dictation.
        f.typed = ""
        f.field = Self.before + Self.after
        await f.insertConfirmed()
        editAndWait(f)
        let added: Int
        if case .learned(let n)? = f.outcomes.last { added = n } else { added = -1 }
        print("ST2 CONTROL duplicate=Politrace added=\(added) lines=\(f.lines.count)")
        #expect(added == 0 && f.lines == ["Politrace"])
        #expect(f.learnLogs == ["dict_learn added=1", "dict_learn added=0"])
    }

    @Test func unreadableValueAddsNothingAndInsertionIsUnchanged() async {
        // Same insertion with and without the learner: result, insertion log lines, held copy and events match.
        let off = Fixture(learnerOn: false)
        await off.insertConfirmed()
        let on = Fixture()
        await on.insertConfirmed()
        editAndWait(on, value: nil)
        let unreadable = on.outcomes == [.skipped(.unreadable)]
        let unchanged = on.result == off.result && on.result == .confirmed && on.insertLogs == off.insertLogs
            && on.inserter.heldText == off.inserter.heldText && on.poster.posted.count == off.poster.posted.count
            && on.poster.pasteCount == off.poster.pasteCount && on.typed == off.typed
        print("ST2 CONTROL unreadable=\(unreadable ? 1 : 0) added=\(on.lines.count) insertion_success_unchanged=\(unchanged ? 1 : 0)")
        #expect(unreadable && on.lines.isEmpty && unchanged)
        #expect(on.valueReads == 1)
        #expect(on.learnLogs == ["dict_learn added=0 skip=unreadable"])
        // A timed-out (unconfirmed) insertion is never observed at all, and stays held exactly as before.
        let timedOut = Fixture()
        timedOut.poster.onEvent = nil   // typing never shows up in the field → confirmation times out
        timedOut.inserter.insert(Self.dictated, onResult: { timedOut.result = $0 })
        for _ in 0..<500 where timedOut.clock.items.isEmpty { await Task.yield(); try? await Task.sleep(for: .milliseconds(1)) }
        timedOut.clock.advance(to: 60)
        #expect(timedOut.result == .timedOut && timedOut.inserter.heldText == Self.dictated)
        #expect(!timedOut.learner.hasPending && timedOut.learner.observations == 0 && timedOut.outcomes.isEmpty)
    }

    @Test func learnerTimerRebindsAndCancels() async {
        // Positive control: without a cancel, the pending observation does run (the counter can see it).
        let ran = Fixture()
        await ran.insertConfirmed()
        editAndWait(ran)
        #expect(ran.learner.observations == 1)
        // A new dictation start cancels: the stale timer fires into nothing.
        let cancelled = Fixture()
        await cancelled.insertConfirmed()
        cancelled.learner.cancelPending()
        editAndWait(cancelled)
        #expect(cancelled.learner.observations == 0 && cancelled.valueReads == 0 && cancelled.lines.isEmpty)
        // A newer insertion rebinds: only ITS observation runs, once.
        let rebound = Fixture()
        await rebound.insertConfirmed()
        rebound.typed = ""
        rebound.field = Self.before + Self.after
        await rebound.insertConfirmed()
        editAndWait(rebound)
        #expect(rebound.learner.observations == 1 && rebound.valueReads == 1)
    }

    // MARK: - Anchor unit checks

    @Test func anchorCaptureAndSpan() throws {
        let a = try #require(InsertionAnchor.capture(inserted: "Polytrace", initial: "x " + Self.before + Self.after,
                                                     confirmed: "x " + Self.before + "Polytrace" + Self.after))
        #expect(!a.prefixAtStart && !a.suffixAtEnd && a.prefix.count == InsertionAnchor.length)
        #expect(a.span(in: "x " + Self.before + "Politrace" + Self.after) == "Politrace")
        // Selection replaced by the dictation: still one placement.
        #expect(InsertionAnchor.capture(inserted: "new", initial: "keep OLD keep", confirmed: "keep new keep") != nil)
        // Not a verbatim placement (the field changed elsewhere too), or several placements → nil.
        #expect(InsertionAnchor.capture(inserted: "abc", initial: "zz", confirmed: "zabcZ") == nil)
        #expect(InsertionAnchor.capture(inserted: "aa", initial: "a", confirmed: "aaa") == nil)
        #expect(InsertionAnchor.capture(inserted: "x", initial: "", confirmed: "") == nil)
        // Empty field: the document boundaries are the anchors; text typed on afterwards is new writing.
        let empty = try #require(InsertionAnchor.capture(inserted: "Polytrace now", initial: "", confirmed: "Polytrace now"))
        #expect(empty.prefixAtStart && empty.suffixAtEnd && empty.span(in: "Politrace now") == "Politrace now")
        // Overlapping prefix occurrences are ambiguous, not unique.
        let overlap = InsertionAnchor(inserted: "b", prefix: "aaaa", suffix: "zzzz", prefixAtStart: false, suffixAtEnd: false)
        #expect(overlap.span(in: "aaaaab zzzz") == nil)
        #expect(overlap.span(in: "xaaaab zzzz") == "b ")
    }

    @Test func spanThatGrewIntoNewWritingIsSkipped() async {
        let f = Fixture()
        f.field = ""
        // Typed into an empty field; the user then writes on after it.
        f.poster.onEvent = { [unowned f] event in
            guard event.keyDown else { return }
            f.typed += String(decoding: event.utf16, as: UTF16.self)
            f.field = f.typed
        }
        await f.insertConfirmed()
        editAndWait(f, value: Self.edited + String(repeating: " and then a long new paragraph", count: 4))
        #expect(f.outcomes == [.skipped(.spanDrift)] && f.learned == 0)
    }

    // MARK: - Host controller: a new dictation start cancels the pending observation

    @Test func newDictationRebindsTimer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("st2-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor(#line) { keys.key(for: "groq-api") != nil }
        let clean = "Polytrace ships the anchor fix today."
        let clipboard = NSPasteboard(name: .init("st2-host-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let pre = "Notes before the dictated sentence: ", post = " And the text after it stays."
        var field: [String]? = [pre + post]
        var pastes = 0
        let identity = Fixture.identity()
        let inserter = TextInserter(pasteboard: clipboard, postKeystroke: {
            pastes += 1
            field = [pre + (clipboard.string(forType: .string) ?? "") + post]
        }, pollInterval: 0.01, axReader: { field }, focusIdentity: { identity })
        let learnerClock = V15PasteConfirmationTests.ManualMainScheduler()
        var valueReads = 0
        let recorder = ST2Recorder()
        let http = ST2HTTP(clean)
        var dependencies = EngineDependencies(recorder: recorder, makeApple: { ST2Apple(clean) }, sttTransport: http,
            groqCleanupTransport: http, localCleanupTransport: http, inserter: inserter,
            panelFactory: { ST2Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.st2") }, manageMedia: false)
        dependencies.focusSnapshot = {
            FocusSnapshot(identity: identity, readValue: { valueReads += 1; return field?.first })
        }
        dependencies.learnerSchedule = learnerClock.schedule
        let controller = AppController(keyStore: keys, paths: AppPaths(home: root), surface: .none, mode: .dictate,
                                       dependencies: dependencies, quotaFileURL: root.appendingPathComponent("quota.json"),
                                       keytermsURL: root.appendingPathComponent("keyterms.txt"))
        let engine = DictationEngine(controller: controller)
        defer { engine.cancel() }
        var notes: [String] = []
        controller.onSessionNote = { notes.append($0) }
        defer { if pastes < 2 { print("ST2 HOST DEBUG pastes=\(pastes) pending=\(controller.editLearner.hasPending) notes=\(notes)") } }

        func dictate() async throws {
            let before = recorder.starts
            engine.start()
            try await waitFor(#line) { recorder.ready && recorder.starts > before && !controller.micStartPending }
            engine.finish()
        }
        // Dictation 1 is inserted and confirmed: its 20-s observation is pending.
        try await dictate()
        try await waitFor(#line) { pastes == 1 && controller.editLearner.hasPending }
        // Dictation 2 starts inside the window: the pending observation is cancelled at once.
        field = [pre + post]   // dictation 2 goes into a fresh copy of the same field
        let before = recorder.starts
        engine.start()
        try await waitFor(#line) { recorder.starts > before }
        #expect(!controller.editLearner.hasPending)
        learnerClock.advance(to: EditLearner.delay + 1)
        let stale = controller.editLearner.observations
        // Positive control: dictation 2's own insertion is observed once, 20 s after IT.
        try await waitFor(#line) { !controller.micStartPending }
        engine.finish()
        try await waitFor(#line) { pastes == 2 && controller.editLearner.hasPending }
        learnerClock.advance(to: 3 * EditLearner.delay)
        print("ST2 CONTROL new_dictation_rebinds_timer stale_observations=\(stale)")
        #expect(stale == 0)
        #expect(controller.editLearner.observations == 1 && valueReads == 1)
    }

    private func waitFor(_ line: Int, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting (line \(line))", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }
}

private final class ST2Panel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) {}
    func hide() {}
    func push(level: Double) {}
}

private final class ST2Recorder: EngineRecorder {
    var isRunning = false
    var onLevel: ((Double) -> Void)?
    var onPCMChunk: (([Int16]) -> Void)?
    var onFirstBuffer: (() -> Void)?
    var onCaptureFailure: ((CaptureFailure) -> Void)?
    var stats = AudioRecorder.CaptureStats()
    var ready = false
    var starts = 0
    var isAllocated = false
    var bridgeHasAudio = false
    func release() { isAllocated = false; isRunning = false }
    func start(device: MicChoice) throws { starts += 1; isAllocated = true; isRunning = true; onFirstBuffer?() }
    func startAsync(device: MicChoice) async throws { try start(device: device) }
    func rebuild() throws {}
    func rebuildAsync() async throws {}
    func resetCapture() { ready = true }
    func stop() -> [Float] {
        isRunning = false
        onPCMChunk?([Int16](repeating: 1000, count: 9600))
        return [Float](repeating: 0.1, count: 9600)
    }
}

private struct ST2Apple: EngineAppleSession {
    let text: String
    init(_ text: String) { self.text = text }
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { text }
    func cancel() {}
}

private actor ST2HTTP: HTTPTransport {
    let text: String
    init(_ text: String) { self.text = text }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let payload: [String: Any] = request.url!.path.contains("transcriptions") ? ["text": text] :
            ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
