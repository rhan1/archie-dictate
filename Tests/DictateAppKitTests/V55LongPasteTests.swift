import AppKit
import Testing
@testable import DictateAppKit

/// H1b (Archie v55): a long dictation pasted into a terminal that hard-wraps
/// and frames its input confirms on the COMPLETE payload; partial evidence
/// (last visible row, unchanged field, equal-length unrelated edit, a suffix
/// that was already there) never confirms and the clipboard keeps the text.
@MainActor @Suite(.serialized)
struct V55LongPasteTests {
    private var payload: String {
        String((0..<100).map { "lorem\($0) ipsum\($0) dolor\($0) " }.joined().prefix(728))
    }

    private var prompt: String { "synthetic terminal prompt awaiting input in a synthetic workspace > " }

    private func framedRows(_ text: String) -> [String] {
        let characters = Array(text)
        return stride(from: 0, to: characters.count, by: 120).map { offset in
            let row = String(characters[offset..<min(offset + 120, characters.count)])
            return "│ " + row.padding(toLength: 120, withPad: " ", startingAt: 0) + " │"
        }
    }

    private func privatePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("dictate-v55-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("ORIGINAL_CLIPBOARD", forType: .string)
        return pb
    }

    /// Runs one paste against a fake AX target: `before` until 0.2 s after the
    /// keystroke, `after` from then on. Returns the result, its time and logs.
    private func paste(before: String, after: String) async -> (TextInserter.Result?, TimeInterval?, [String], NSPasteboard) {
        let pb = privatePasteboard()
        let clock = V15PasteConfirmationTests.ManualMainScheduler()
        let ax = V15PasteConfirmationTests.AXMockBox()
        let logs = V15PasteConfirmationTests.LogBox()
        ax.texts = [before]
        var result: TextInserter.Result?
        var completedAt: TimeInterval?
        let inserter = TextInserter(pasteboard: pb, postKeystroke: {
            clock.schedule(0.2) { ax.texts = [after] }
        }, schedule: clock.schedule, pollInterval: 0.1, timeout: 10,
            axReader: { ax.texts }, logger: logs.log, now: { clock.now })
        inserter.insert(payload, onResult: { result = $0; completedAt = clock.now })
        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(!clock.items.isEmpty)
        clock.advance(to: 10.1)
        return (result, completedAt, logs.lines, pb)
    }

    @Test func wrappedTerminalConfirmsOnTheCompletePayload() async {
        let text = payload
        #expect(text.count == 728)
        let after = framedRows(prompt + text).joined(separator: "\n")
        #expect(!after.contains(text))
        let (result, at, logs, pb) = await paste(before: framedRows(prompt).joined(separator: "\n"), after: after)
        defer { pb.releaseGlobally() }
        let restored = pb.string(forType: .string) == "ORIGINAL_CLIPBOARD"
        print("H1B GREEN chars=\(text.count) full_new_occurrence=1 result=\(result == .confirmed ? "confirmed" : "timedOut") clipboard_restored=\(restored ? 1 : 0)")
        #expect(result == .confirmed)
        #expect((at ?? 10) < 1)
        #expect(logs == ["paste_confirm=ax", "insertion=paste reason=no_focus confirmed=1"])
        #expect(restored)
    }

    @Test(arguments: ["last_row_only", "unchanged", "equal_length_unrelated", "preexisting_suffix"])
    func partialEvidenceNeverConfirms(target: String) async {
        let text = payload
        let rows = framedRows(prompt + text)
        let empty = framedRows(prompt).joined(separator: "\n")
        let before: String
        let after: String
        switch target {
        case "last_row_only": before = empty; after = rows.last!
        case "unchanged": before = empty; after = empty
        case "equal_length_unrelated":
            before = empty
            after = framedRows(prompt + String(repeating: "x", count: text.count)).joined(separator: "\n")
        default: // the field already showed the payload's last row before this paste
            before = rows.last!; after = rows.last! + "\n" + rows.last!
        }
        let (result, at, logs, pb) = await paste(before: before, after: after)
        defer { pb.releaseGlobally() }
        let retained = pb.string(forType: .string) == text
        print("H1B CONTROL target=\(target) complete_evidence=0 result=\(result == .confirmed ? "confirmed" : "timedOut") clipboard_retained=\(retained ? 1 : 0)")
        #expect(result == .timedOut)
        #expect(abs((at ?? 0) - 10) < 0.11)
        #expect(logs == ["paste_confirm=timeout", "insertion=paste reason=no_focus confirmed=0"])
        #expect(retained)
    }

    /// The control above must catch a matcher that accepts a suffix.
    @Test func suffixOnlyMatcherIsRejected() {
        let text = payload
        let initial = framedRows(prompt).joined(separator: "\n")
        let current = framedRows(prompt + text).last!
        func normalized(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter {
                !$0.properties.isWhitespace && !(0x2500...0x257F).contains($0.value)
            }))
        }
        let tail = String(normalized(text).suffix(48))
        let mutant = normalized(current).contains(tail) && !normalized(initial).contains(tail)
        let real = TextInserter.hasCompleteNewOccurrence(of: text, initial: initial, current: current)
        print("H1B MUTATION suffix_only confirmed=\(mutant ? 1 : 0) result=\(mutant && !real ? "FAIL" : "PASS") real_confirmed=\(real ? 1 : 0)")
        #expect(mutant)
        #expect(!real)
    }

    @Test func verbatimTextFieldControl() async {
        let (result, _, logs, pb) = await paste(before: prompt, after: prompt + payload)
        defer { pb.releaseGlobally() }
        print("LONGPASTE CONTROL target=text_field result=\(result == .confirmed ? "confirmed" : "timedOut")")
        #expect(result == .confirmed)
        #expect(logs == ["paste_confirm=ax", "insertion=paste reason=no_focus confirmed=1"])
    }

    @Test func unrelatedWrappedOutputNeverConfirms() async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let clock = V15PasteConfirmationTests.ManualMainScheduler()
        let ax = V15PasteConfirmationTests.AXMockBox()
        let logs = V15PasteConfirmationTests.LogBox()
        ax.texts = [framedRows(prompt).joined(separator: "\n")]
        let text = payload
        var result: TextInserter.Result?
        var completedAt: TimeInterval?
        let inserter = TextInserter(pasteboard: pb, postKeystroke: {
            for step in 1...49 {
                clock.schedule(Double(step) * 0.2) {
                    ax.texts = [framedRows("unrelated build output stage \(step) " + String(repeating: "working ", count: step * 10)).joined(separator: "\n")]
                }
            }
        }, schedule: clock.schedule, pollInterval: 0.1, timeout: 10,
            axReader: { ax.texts }, logger: logs.log, now: { clock.now })
        inserter.insert(text, onResult: { result = $0; completedAt = clock.now })
        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(!clock.items.isEmpty)
        clock.advance(to: 9.9)
        #expect(result == nil)
        #expect(logs.lines.isEmpty)
        clock.advance(to: 10.0)
        print("LONGPASTE NEGATIVE target=busy_wrapped result=\(result == .timedOut ? "timedOut" : "confirmed")")
        #expect(result == .timedOut)
        #expect(abs((completedAt ?? 0) - 10) < 1e-6)
        #expect(logs.lines == ["paste_confirm=timeout", "insertion=paste reason=no_focus confirmed=0"])
        let retained = pb.string(forType: .string) == text
        #expect(retained)
    }
}
