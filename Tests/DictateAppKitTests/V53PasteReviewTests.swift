import AppKit
import Testing
@testable import DictateAppKit

@MainActor @Suite(.serialized)
struct V53PasteReviewTests {
    @Test func busyTargetControlsAndFalseConfirmation() async {
        for scenario in ["late-success", "timeout", "unrelated-edit"] {
            let pb = NSPasteboard(name: .init("dictate-v53-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.setString("ORIGINAL", forType: .string)
            let clock = V15PasteConfirmationTests.ManualMainScheduler()
            let ax = V15PasteConfirmationTests.AXMockBox()
            ax.texts = scenario == "unrelated-edit" ? ["prior WORDS"] : [""]
            let logs = V15PasteConfirmationTests.LogBox()
            var targetRead = "not-read"
            var completed = false
            var result: TextInserter.Result?
            let inserter = TextInserter(pasteboard: pb, postKeystroke: {
                if scenario == "unrelated-edit" {
                    clock.schedule(0.2) { ax.texts = ["unrelated edit: prior WORDS"] }
                }
                if scenario != "timeout" {
                    clock.schedule(1.5) {
                        targetRead = pb.string(forType: .string) ?? "nil"
                        ax.texts = [(ax.texts?.first ?? "") + targetRead]
                    }
                }
            }, schedule: clock.schedule, axReader: { ax.texts }, logger: logs.log, now: { clock.now })
            inserter.insert("WORDS", onResult: { result = $0 }, completion: { completed = true })
            for _ in 0..<500 where clock.items.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
            clock.advance(to: 1.0)
            #expect(!completed)
            #expect(pb.string(forType: .string) == "WORDS")
            clock.advance(to: scenario == "timeout" ? 10.1 : 1.6)
            let clipboard = pb.string(forType: .string) ?? "nil"
            print("V522 PASTE scenario=\(scenario) target_read=\(targetRead) clipboard=\(clipboard) completed=\(completed) log=\(logs.lines)")
            #expect(completed)
            #expect(result == (scenario == "timeout" ? .timedOut : .confirmed))
            #expect(targetRead == (scenario == "timeout" ? "not-read" : "WORDS"))
            #expect(clipboard == (scenario == "timeout" ? "WORDS" : "ORIGINAL"))
            #expect(logs.lines == [scenario == "timeout" ? "paste_confirm=timeout" : "paste_confirm=ax"])
        }
    }
    @Test func selectingExistingTextNeverConfirmsAnInsertion() async {
        let pb = NSPasteboard(name: .init("dictate-v53-selection-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.setString("ORIGINAL", forType: .string)
        let clock = V15PasteConfirmationTests.ManualMainScheduler()
        let ax = V15PasteConfirmationTests.AXMockBox()
        ax.texts = ["prior WORDS", ""]
        var result: TextInserter.Result?
        let inserter = TextInserter(pasteboard: pb, postKeystroke: { ax.texts = ["prior WORDS", "WORDS"] },
            schedule: clock.schedule, axReader: { ax.texts }, logger: { _ in }, now: { clock.now })
        inserter.insert("WORDS", onResult: { result = $0 })
        for _ in 0..<500 where clock.items.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
        clock.advance(to: 1)
        print("R0 SELECTION_ONLY confirmed=\(result == .confirmed) clipboard=\(pb.string(forType: .string) ?? "nil")")
        #expect(result == nil)
        #expect(pb.string(forType: .string) == "WORDS")
        clock.advance(to: 10.1)
        #expect(result == .timedOut)
    }

}
