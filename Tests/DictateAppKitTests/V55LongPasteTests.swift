import AppKit
import Testing
@testable import DictateAppKit

@MainActor @Suite(.serialized)
struct V55LongPasteTests {
    private var payload: String {
        String((0..<100).map { "lorem\($0) ipsum\($0) dolor\($0) " }.joined().prefix(728))
    }

    // The prompt offsets the final row so it contains the full 48-character
    // normalized tail, even though it exposes only a fraction of the payload.
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

    @Test func wrappedTerminalConfirms() async {
        await checkLongPaste(target: "wrapped_tui")
    }

    @Test func lastVisibleRowConfirms() async {
        await checkLongPaste(target: "last_row_only")
    }

    @Test func verbatimTextFieldControl() async {
        await checkLongPaste(target: "text_field")
    }

    private func checkLongPaste(target: String) async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let clock = V15PasteConfirmationTests.ManualMainScheduler()
        let ax = V15PasteConfirmationTests.AXMockBox()
        let logs = V15PasteConfirmationTests.LogBox()
        let text = payload
        #expect(text.count == 728)
        let rows = framedRows(prompt + text)
        #expect(rows.count > 1)
        #expect(rows.allSatisfy { $0.count == 124 })
        let current: String
        switch target {
        case "wrapped_tui": current = rows.joined(separator: "\n")
        case "last_row_only": current = rows.last!
        default: current = prompt + text
        }
        if target != "text_field" {
            #expect(!current.contains(text))
        }
        // Independently establish that the tail fixture really includes all
        // 48 non-whitespace characters needed for the partial-visibility path.
        let tail = String(text.filter { !$0.isWhitespace }.suffix(48))
        #expect(current.filter { !$0.isWhitespace && $0 != "│" }.contains(tail))
        ax.texts = [target == "text_field" ? prompt : framedRows(prompt).joined(separator: "\n")]
        var result: TextInserter.Result?
        var completedAt: TimeInterval?
        let inserter = TextInserter(pasteboard: pb, postKeystroke: {
            clock.schedule(0.2) { ax.texts = [current] }
        }, schedule: clock.schedule, pollInterval: 0.1, timeout: 10,
            axReader: { ax.texts }, logger: logs.log, now: { clock.now })
        inserter.insert(text, onResult: { result = $0; completedAt = clock.now })
        for _ in 0..<500 where clock.items.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(!clock.items.isEmpty)
        clock.advance(to: 0.1)
        #expect(result == nil)
        clock.advance(to: 0.9)
        let confirmedWithinOneSecond = result == .confirmed && (completedAt ?? 10) < 1
        clock.advance(to: 10.1)
        if target == "text_field" {
            print("LONGPASTE CONTROL target=text_field result=\(result == .confirmed ? "confirmed" : "timedOut")")
        } else {
            let phase = result == .confirmed ? "GREEN" : "RED"
            print("LONGPASTE \(phase) target=\(target) chars=\(text.count) result=\(result == .confirmed ? "confirmed" : "timedOut") log=\(logs.lines.last ?? "none")")
        }
        #expect(result == .confirmed)
        #expect(confirmedWithinOneSecond)
        #expect(logs.lines == ["paste_confirm=ax"])
        let restored = pb.string(forType: .string) == "ORIGINAL_CLIPBOARD"
        #expect(restored)
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
        #expect(logs.lines == ["paste_confirm=timeout"])
        let retained = pb.string(forType: .string) == text
        #expect(retained)
    }
}
