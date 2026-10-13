import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

@Suite("InsertionTests")
@MainActor
struct InsertionTests {
    private func seededPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("dictate-insertion-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)
        return pb
    }

    @Test func normalRestore() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        var seen: String?
        let inserter = TextInserter(pasteboard: pb, postKeystroke: { seen = pb.string(forType: .string) })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            inserter.insert("DICTATION") { done.resume() }
        }
        #expect(seen == "DICTATION")
        #expect(pb.string(forType: .string) == "ORIGINAL")
    }

    @Test func userCopyWins() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let inserter = TextInserter(pasteboard: pb, postKeystroke: {})
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            inserter.insert("DICTATION") { done.resume() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pb.clearContents()
                pb.setString("NEW_USER_COPY", forType: .string)
            }
        }
        #expect(pb.string(forType: .string) == "NEW_USER_COPY")
    }

    @Test func overlappingInsertionsRestoreOriginalInFIFOOrder() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        var keystrokes: [String] = []
        var completions: [String] = []
        var atCompletion: [String] = []
        let inserter = TextInserter(pasteboard: pb, postKeystroke: {
            keystrokes.append(pb.string(forType: .string) ?? "nil")
        })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            inserter.insert("DICTATION_ONE") {
                completions.append("one")
                atCompletion.append(pb.string(forType: .string) ?? "nil")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                inserter.insert("DICTATION_TWO") {
                    completions.append("two")
                    atCompletion.append(pb.string(forType: .string) ?? "nil")
                    done.resume()
                }
            }
        }
        #expect(keystrokes == ["DICTATION_ONE", "DICTATION_TWO"])
        #expect(completions == ["one", "two"])
        #expect(atCompletion == ["ORIGINAL", "ORIGINAL"])
        #expect(pb.string(forType: .string) == "ORIGINAL")
    }

    /// v1.12 (L4): the restore window on a manual main-queue clock — a recipient that reads the
    /// clipboard 600 ms after ⌘V gets the dictation, whatever the machine load; the original is back
    /// exactly at `restoreDelay`.
    final class ManualMainScheduler: @unchecked Sendable {
        private(set) var now: TimeInterval = 0
        private(set) var items: [(at: TimeInterval, work: () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) { items.append((now + delay, work)) }
        /// Runs every item due by `t` in time order (call on the main queue).
        func advance(to t: TimeInterval) {
            while let index = items.indices.filter({ items[$0].at <= t + 1e-9 }).min(by: { items[$0].at < items[$1].at }) {
                let item = items.remove(at: index)
                now = item.at
                item.work()
            }
            now = t
        }
    }

    @MainActor @Test func recipientReadsDictationAfter600Milliseconds() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let clock = ManualMainScheduler()
        var slowReader: String?
        let inserter = TextInserter(pasteboard: pb, postKeystroke: {
            clock.schedule(0.6) { slowReader = pb.string(forType: .string) }
        }, schedule: clock.schedule)
        inserter.insert("DICTATION")
        for _ in 0..<500 where clock.items.count < 2 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(clock.items.count == 2)                       // the reader and the restore, nothing ran yet
        clock.advance(to: 0.6)
        #expect(slowReader == "DICTATION")
        clock.advance(to: TextInserter.restoreDelay - 0.001)
        #expect(pb.string(forType: .string) == "DICTATION")
        clock.advance(to: TextInserter.restoreDelay)
        #expect(pb.string(forType: .string) == "ORIGINAL")
    }

    /// RED twin: the v1.11 wall-clock form under a 1.2 s stall of the queue the restore window runs
    /// on (a private queue standing in for a loaded main queue — never stall the shared main queue
    /// in a parallel suite): the 750 ms wall-clock wait elapses before the 600 ms reader could run.
    @Test func recipientReadsDictationAfter600MillisecondsRealClockUnderStallRed() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let box = ReaderBox()
        let loaded = DispatchQueue(label: "insertion-tests.loaded")
        let inserter = TextInserter(pasteboard: pb, postKeystroke: {
            loaded.asyncAfter(deadline: .now() + 0.6) { box.value = pb.string(forType: .string) }
            loaded.asyncAfter(deadline: .now() + 0.1) { Thread.sleep(forTimeInterval: 1.2) }   // the stall: busy 0.1–1.3 s
        }, schedule: { delay, work in loaded.asyncAfter(deadline: .now() + delay, execute: work) })
        inserter.insert("DICTATION")
        let seen = await Task.detached { () -> String? in
            try? await Task.sleep(nanoseconds: 750_000_000)
            return box.value
        }.value
        withKnownIssue("a loaded queue breaks the wall-clock reader bound") {
            #expect(seen == "DICTATION")
        }
        loaded.sync {}                                         // no callback outlives this pasteboard
        try? await Task.sleep(nanoseconds: 500_000_000)
        loaded.sync {}
    }
    final class ReaderBox: @unchecked Sendable { var value: String? }
}

/// F1 initially has no helper to call. Check the actual controller's contract
/// without constructing it (which would initialise audio/UI components).
@Suite("InsertionTargetTests")
struct InsertionTargetTests {
    @Test func samePIDPastesEvenIfBundleIDDiffers() {
        let start = InsertionTarget(pid: 123, bundleID: "editor")
        let now = InsertionTarget(pid: 123, bundleID: "other")
        #expect(InsertionTarget.decide(start: start, now: now) == .paste)
    }

    @Test func differentPIDHoldsEvenIfBundleIDMatches() {
        let start = InsertionTarget(pid: 123, bundleID: "editor")
        let now = InsertionTarget(pid: 456, bundleID: "editor")
        #expect(InsertionTarget.decide(start: start, now: now) == .hold)
    }

    @Test func missingCurrentTargetHolds() {
        #expect(InsertionTarget.decide(start: InsertionTarget(pid: 123, bundleID: "editor"), now: nil) == .hold)
    }

    @Test func unknownRecordingTargetPastes() {
        #expect(InsertionTarget.decide(start: nil, now: InsertionTarget(pid: 456, bundleID: "chat")) == .paste)
        #expect(InsertionTarget.decide(start: nil, now: nil) == .paste)
    }

    @Test @MainActor func focusChangeWhileQueuedSkipsKeystroke() async {
        let pb = NSPasteboard(name: .init("dictate-focus-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)
        let start = InsertionTarget(pid: 123, bundleID: "editor")
        var now = start
        var seen: [String] = []
        var completions: [Int] = []
        var decisions: [InsertionTarget.Decision] = []
        let inserter = TextInserter(pasteboard: pb, postKeystroke: { seen.append(pb.string(forType: .string) ?? "nil") })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            inserter.insert("DICTATION_ONE", shouldInsert: {
                let decision = InsertionTarget.decide(start: start, now: now)
                decisions.append(decision)
                return decision == .paste
            }) { completions.append(1) }
            inserter.insert("DICTATION_TWO", shouldInsert: {
                let decision = InsertionTarget.decide(start: start, now: now)
                decisions.append(decision)
                if decision == .hold {
                    pb.clearContents()
                    pb.setString("HELD_DICTATION", forType: .string)
                }
                return decision == .paste
            }) { completions.append(2); done.resume() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                now = InsertionTarget(pid: 456, bundleID: "chat")
            }
        }
        #expect(decisions == [.paste, .hold])
        #expect(seen == ["DICTATION_ONE"])
        #expect(completions == [1, 2])
        #expect(pb.string(forType: .string) == "HELD_DICTATION")
    }

    @Test func heldLogKeepsCharacterCountAndReason() {
        let entry = DictationLogEntry(time: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 1,
                                      audioBytes: 44, latencyMs: 10, chars: 49, frontmostBundleID: "chat",
                                      outcome: .held("focus_changed"))
        #expect(DictationOutcome.held("focus_changed").label == "held:focus_changed")
        #expect(entry.formatted().contains("chars=49 app=chat outcome=held:focus_changed"))
    }

    @Test func controllerLocksRecordingTargetBeforePasting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DictateAppKit/AppController.swift"), encoding: .utf8)
        #expect(source.contains("recordingTarget = Self.frontmostTarget()"))
        #expect(source.contains("InsertionTarget.decide(start:"))
        #expect(source.contains(".held(\"focus_changed\")"))
    }
}
