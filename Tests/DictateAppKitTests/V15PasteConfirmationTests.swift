import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

@Suite("V15PasteConfirmationTests")
@MainActor
struct V15PasteConfirmationTests {
    final class ManualMainScheduler: @unchecked Sendable {
        private(set) var now: TimeInterval = 0
        private(set) var items: [(at: TimeInterval, work: () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            items.append((now + delay, work))
        }

        func advance(to t: TimeInterval) {
            while let index = items.indices.filter({ items[$0].at <= t + 1e-9 }).min(by: { items[$0].at < items[$1].at }) {
                let item = items.remove(at: index)
                now = item.at
                item.work()
            }
            now = t
        }
    }

    private func seededPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("dictate-v15-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("ORIGINAL_CLIPBOARD", forType: .string)
        return pb
    }

    final class AXMockBox: @unchecked Sendable {
        var texts: [String]? = []
    }

    final class LogBox: @unchecked Sendable {
        var lines: [String] = []
        func log(_ line: String) {
            lines.append(line)
        }
    }

    // 1. Late read beyond 1s no restore: target reads clipboard at 1.5s, no restore at 1.0s
    @Test func lateReadBeyond1sNoRestore() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let clock = ManualMainScheduler()
        let axBox = AXMockBox()
        let logBox = LogBox()
        var lateReaderSaw: String?

        let inserter = TextInserter(
            pasteboard: pb,
            postKeystroke: {
                clock.schedule(1.5) {
                    lateReaderSaw = pb.string(forType: .string)
                    axBox.texts = ["DICTATION_LATE"]
                }
            },
            schedule: clock.schedule,
            pollInterval: 0.1,
            timeout: 10.0,
            axReader: { axBox.texts },
            logger: logBox.log,
            now: { clock.now }
        )

        inserter.insert("DICTATION_LATE")
        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // At 1.0s (the old fixed restoreDelay): clipboard must NOT be restored yet
        clock.advance(to: 1.0)
        #expect(pb.string(forType: .string) == "DICTATION_LATE")
        #expect(!logBox.lines.contains("paste_confirm=ax"))

        // At 1.5s: target app reads clipboard
        clock.advance(to: 1.5)
        #expect(lateReaderSaw == "DICTATION_LATE")

        // At 1.6s: next AX poll confirms text, restores old clipboard
        clock.advance(to: 1.6)
        #expect(pb.string(forType: .string) == "ORIGINAL_CLIPBOARD")
        #expect(logBox.lines.contains("paste_confirm=ax"))
    }

    // 2. AX success restores: confirmed restore guarded by ourChangeCount and logs paste_confirm=ax
    @Test func axSuccessRestores() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let clock = ManualMainScheduler()
        let axBox = AXMockBox()
        let logBox = LogBox()
        var completed = false

        let inserter = TextInserter(
            pasteboard: pb,
            postKeystroke: {
                clock.schedule(0.2) {
                    axBox.texts = ["Prefix text ... DICTATION_SUCCESS"]
                }
            },
            schedule: clock.schedule,
            pollInterval: 0.1,
            timeout: 10.0,
            axReader: { axBox.texts },
            logger: logBox.log,
            now: { clock.now }
        )

        inserter.insert("DICTATION_SUCCESS") {
            completed = true
        }

        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // Before 0.2s: not confirmed
        clock.advance(to: 0.1)
        #expect(pb.string(forType: .string) == "DICTATION_SUCCESS")
        #expect(!completed)

        // At 0.2s and next poll (0.3s): confirmed
        clock.advance(to: 0.3)
        #expect(completed)
        #expect(pb.string(forType: .string) == "ORIGINAL_CLIPBOARD")
        #expect(logBox.lines.contains("paste_confirm=ax"))
    }

    // 3. Timeout dictation retained: on timeout do NOT restore; retain dictation so manual ⌘V can recover, log paste_confirm=timeout
    @Test func timeoutDictationRetained() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let clock = ManualMainScheduler()
        let axBox = AXMockBox()
        let logBox = LogBox()
        var completed = false

        let inserter = TextInserter(
            pasteboard: pb,
            postKeystroke: {},
            schedule: clock.schedule,
            pollInterval: 0.1,
            timeout: 10.0,
            axReader: { axBox.texts }, // stays empty
            logger: logBox.log,
            now: { clock.now }
        )

        inserter.insert("RETAIN_ME_ON_TIMEOUT") {
            completed = true
        }

        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // At 9.9s: still polling, not timed out yet
        clock.advance(to: 9.9)
        #expect(!completed)
        #expect(pb.string(forType: .string) == "RETAIN_ME_ON_TIMEOUT")

        // At 10.0s: timeout triggers
        clock.advance(to: 10.0)
        #expect(completed)
        // Must NOT restore: retain dictation so manual command V can recover
        #expect(pb.string(forType: .string) == "RETAIN_ME_ON_TIMEOUT")
        #expect(logBox.lines.contains("paste_confirm=timeout"))
        #expect(!logBox.lines.contains("paste_confirm=ax"))
    }

    // 4. New copy never clobbered: user copy during wait is preserved
    @Test func newCopyNeverClobbered() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let clock = ManualMainScheduler()
        let axBox = AXMockBox()
        let logBox = LogBox()

        let inserter = TextInserter(
            pasteboard: pb,
            postKeystroke: {
                clock.schedule(0.5) {
                    // User copies something newer while paste confirmation is pending
                    pb.clearContents()
                    pb.setString("USER_NEW_COPY", forType: .string)
                }
                clock.schedule(0.7) {
                    axBox.texts = ["DICTATION_CLOBBER_TEST"]
                }
            },
            schedule: clock.schedule,
            pollInterval: 0.1,
            timeout: 10.0,
            axReader: { axBox.texts },
            logger: logBox.log,
            now: { clock.now }
        )

        inserter.insert("DICTATION_CLOBBER_TEST")
        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        clock.advance(to: 1.0)
        // User's newer copy must win over old clipboard snapshot
        #expect(pb.string(forType: .string) == "USER_NEW_COPY")
        #expect(logBox.lines.contains("paste_confirm=ax"))
    }

    // 5. Queued next paste waits: queue semantics preserved
    @Test func queuedNextPasteWaits() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let clock = ManualMainScheduler()
        let axBox = AXMockBox()
        let logBox = LogBox()
        var keystrokes: [String] = []
        var completions: [String] = []

        let inserter = TextInserter(
            pasteboard: pb,
            postKeystroke: {
                keystrokes.append(pb.string(forType: .string) ?? "nil")
            },
            schedule: clock.schedule,
            pollInterval: 0.1,
            timeout: 10.0,
            axReader: { axBox.texts },
            logger: logBox.log,
            now: { clock.now }
        )

        inserter.insert("PASTE_ONE") {
            completions.append("one")
        }
        inserter.insert("PASTE_TWO") {
            completions.append("two")
        }

        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // Only first paste keystroke has run
        #expect(keystrokes == ["PASTE_ONE"])
        #expect(completions.isEmpty)

        // Advance to 0.5s: first paste still in flight
        clock.advance(to: 0.5)
        #expect(keystrokes == ["PASTE_ONE"])
        #expect(completions.isEmpty)

        // At 0.6s, first paste confirms
        axBox.texts = ["PASTE_ONE"]
        clock.advance(to: 0.6)
        #expect(completions == ["one"])

        // Second paste should now be dequeued and in flight
        #expect(keystrokes == ["PASTE_ONE", "PASTE_TWO"])
        #expect(pb.string(forType: .string) == "PASTE_TWO")

        // Second paste confirms at 0.8s
        axBox.texts = ["PASTE_ONE and PASTE_TWO"]
        clock.advance(to: 0.8)
        #expect(completions == ["one", "two"])
        #expect(pb.string(forType: .string) == "ORIGINAL_CLIPBOARD")
    }

    // 6. No text in logs: privacy requirement - logs counts/stages only, no speech/transcript text
    @Test func noTextInLogs() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let clock = ManualMainScheduler()
        let axBox = AXMockBox()
        let logBox = LogBox()
        let secretText = "SECRET_DICTATED_PHRASE_12345"

        let inserter = TextInserter(
            pasteboard: pb,
            postKeystroke: {
                clock.schedule(0.2) {
                    axBox.texts = [secretText]
                }
            },
            schedule: clock.schedule,
            pollInterval: 0.1,
            timeout: 10.0,
            axReader: { axBox.texts },
            logger: logBox.log,
            now: { clock.now }
        )

        inserter.insert(secretText)
        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        clock.advance(to: 0.3)
        #expect(logBox.lines.contains("paste_confirm=ax"))
        // Guarantee no speech/transcript text leaked into log messages
        for line in logBox.lines {
            #expect(!line.contains(secretText))
            #expect(!line.contains("SECRET"))
        }
    }

    // 7. Don't confirm old same suffix: if target element already had suffix, wait for change
    @Test func dontConfirmOldSameSuffix() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        let clock = ManualMainScheduler()
        let axBox = AXMockBox()
        let logBox = LogBox()
        let dictation = "SUFFIX_TEXT"

        // Target field already contained "SUFFIX_TEXT" before ⌘V was posted
        axBox.texts = ["EXISTING_CONTENT_SUFFIX_TEXT"]

        let inserter = TextInserter(
            pasteboard: pb,
            postKeystroke: {
                // At 0.4s, actual paste lands and changes the text
                clock.schedule(0.4) {
                    axBox.texts = ["EXISTING_CONTENT_SUFFIX_TEXT + SUFFIX_TEXT"]
                }
            },
            schedule: clock.schedule,
            pollInterval: 0.1,
            timeout: 10.0,
            axReader: { axBox.texts },
            logger: logBox.log,
            now: { clock.now }
        )

        inserter.insert(dictation)
        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        // At 0.1s - 0.3s: target still has old text; must NOT confirm prematurely
        clock.advance(to: 0.3)
        #expect(pb.string(forType: .string) == dictation)
        #expect(!logBox.lines.contains("paste_confirm=ax"))

        // At 0.5s: new text has landed and contains suffix; confirms
        clock.advance(to: 0.5)
        #expect(pb.string(forType: .string) == "ORIGINAL_CLIPBOARD")
        #expect(logBox.lines.contains("paste_confirm=ax"))
    }
    @Test func stalledQueueUsesWallDeadline() async {
        let pb = seededPasteboard()
        defer { pb.releaseGlobally() }
        var work: (() -> Void)?
        var now: TimeInterval = 0
        var finished = false
        var log: [String] = []
        let inserter = TextInserter(pasteboard: pb, postKeystroke: {},
            schedule: { _, callback in work = callback }, axReader: { [] },
            logger: { log.append($0) }, now: { now })
        inserter.insert("RECOVERY") { finished = true }
        for _ in 0..<500 where work == nil { await Task.yield() }
        now = 11
        work?()
        #expect(finished)
        #expect(pb.string(forType: .string) == "RECOVERY")
        #expect(log == ["paste_confirm=timeout", "insertion=paste reason=no_focus confirmed=0"])
    }

}
