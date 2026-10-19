import AppKit
import Testing
@testable import DictateAppKit

@MainActor @Suite(.serialized)
struct V18TypedInsertionTests {
    final class Poster: KeyEventPosting {
        var prepared: [InsertionKeyEvent] = []
        var posted: [InsertionKeyEvent] = []
        var pasteCount = 0
        var accepts = true
        var onEvent: ((InsertionKeyEvent) -> Void)?
        var onPaste: (() -> Void)?
        func prepare(_ events: [InsertionKeyEvent]) -> Bool { prepared = events; return accepts }
        func postPreparedEvent(at index: Int) {
            let event = prepared[index]
            posted.append(event)
            onEvent?(event)
        }
        func postPaste() { pasteCount += 1; onPaste?() }
    }

    final class Fixture {
        let pb = NSPasteboard(name: .init("dictate-c2-\(UUID().uuidString)"))
        let clock = V15PasteConfirmationTests.ManualMainScheduler()
        let poster = Poster()
        var texts: [String]? = [""]
        var logs: [String] = []
        var result: TextInserter.Result?
        var completedAt: TimeInterval?
        var typed = ""
        var confirmsTyping = true
        var eligibility: TypingEligibility = .editable
        lazy var inserter = TextInserter(pasteboard: pb, postKeystroke: { [unowned self] in poster.postPaste() },
            keyEventPosting: poster, typingEligibility: { [unowned self] in eligibility },
            schedule: clock.schedule, axReader: { [unowned self] in texts },
            logger: { [unowned self] in logs.append($0) }, now: { [unowned self] in clock.now })
        init() {
            pb.setString("ORIGINAL", forType: .string)
            poster.onEvent = { [unowned self] event in
                if event.keyDown {
                    typed += String(decoding: event.utf16, as: UTF16.self)
                    if confirmsTyping { texts = [typed] }
                }
            }
            poster.onPaste = { [unowned self] in texts = [pb.string(forType: .string) ?? ""] }
        }
        deinit { pb.releaseGlobally() }
        func start(_ payload: String) async {
            inserter.insert(payload, onResult: { [unowned self] in result = $0; completedAt = clock.now })
            for _ in 0..<500 where clock.items.isEmpty {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(!clock.items.isEmpty)
        }
    }

    @Test func singleLine728TypesWithoutBorrowingClipboard() async {
        let f = Fixture()
        let text = String(repeating: "abcdefgh ", count: 81).prefix(728)
        let baseline = f.pb.changeCount
        await f.start(String(text))
        f.clock.advance(to: 10.1)
        let delta = f.pb.changeCount - baseline
        if f.poster.pasteCount > 0 { print("C2 RED insertion=paste chars=728") }
        else {
            print("C2 GREEN insertion=typed chars=728 events=\(f.poster.posted.count) ms=\(Int((f.completedAt ?? 10) * 1000)) confirmed=\(f.result == .confirmed ? 1 : 0) clipboard_changecount_delta=\(delta)")
        }
        #expect(f.poster.pasteCount == 0)
        #expect(f.poster.posted.count > 0)
        #expect(f.result == .confirmed)
        #expect((f.completedAt ?? 10) < 2)
        #expect(delta == 0)
        #expect(f.typed == text)
    }
}
