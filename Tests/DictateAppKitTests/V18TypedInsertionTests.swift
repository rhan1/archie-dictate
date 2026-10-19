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
        var bundleID: String? = "dev.warp.Warp-Stable"
        var prefs: [String: Bool] = [:]
        var customReader: ((String, String) -> Bool?)? = nil
        lazy var inserter = TextInserter(pasteboard: pb, postKeystroke: { [unowned self] in poster.postPaste() },
            keyEventPosting: poster, typingEligibility: { [unowned self] in eligibility },
            targetBundleID: { [unowned self] in bundleID },
            substitutionPolicy: TextSubstitutionPolicy(reader: { [unowned self] key, bundle in
                customReader?(key, bundle) ?? prefs[key]
            }),
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

    @Test func secureFieldUsesPaste() async {
        let f = Fixture()
        f.eligibility = .secure
        await f.start("secure fixture")
        f.clock.advance(to: 10.1)
        #expect(f.result == .confirmed)
        #expect(f.poster.posted.isEmpty)
        #expect(f.poster.pasteCount == 1)
        #expect(f.logs == ["paste_confirm=ax", "insertion=paste reason=secure confirmed=1"])
        print("C2 CONTROL secure_field insertion=paste confirmed=1")
    }

    @Test(arguments: ["\n", "\r", "\t", "\0", "\u{7f}", "\u{85}", "\u{2028}", "\u{2029}"])
    func controlsUsePasteVerbatim(control: String) async {
        let f = Fixture()
        let text = "fixture" + control + "payload"
        await f.start(text)
        f.clock.advance(to: 10.1)
        #expect(f.result == .confirmed)
        #expect(f.poster.posted.isEmpty)
        #expect(f.poster.pasteCount == 1)
        #expect(f.texts == [text])
        #expect(f.logs == ["paste_confirm=ax", "insertion=paste reason=control_chars confirmed=1"])
        if control == "\n" { print("C2 CONTROL multiline insertion=paste reason=control_chars") }
    }

    @Test func noEditableFocusUsesPaste() async {
        let f = Fixture()
        f.eligibility = .noFocus
        await f.start("fixture")
        f.clock.advance(to: 10.1)
        #expect(f.poster.posted.isEmpty)
        #expect(f.poster.pasteCount == 1)
        #expect(f.logs == ["paste_confirm=ax", "insertion=paste reason=no_focus confirmed=1"])
    }

    @Test func typedUnconfirmedNeverPastes() async {
        let f = Fixture()
        f.confirmsTyping = false
        let text = String(repeating: "fixture ", count: 91)
        let baseline = f.pb.changeCount
        await f.start(text)
        f.clock.advance(to: 9.9)
        #expect(f.result == nil)
        f.clock.advance(to: 10)
        #expect(f.result == .timedOut)
        #expect(f.completedAt == 10)
        #expect(f.poster.pasteCount == 0)
        #expect(f.pb.changeCount == baseline)
        #expect(f.inserter.heldText == text)
        #expect(f.logs.count == 1)
        #expect(f.logs.first?.hasSuffix("confirmed=0") == true)
        #expect(!f.logs.contains { $0.contains("paste_confirm") || $0.contains(text) })
        print("C2 CONTROL typed_unconfirmed result=timedOut pasted_after=0 held=1")
    }

    @Test func optionHeldCannotLeakIntoEvents() async {
        let f = Fixture()
        // A fake physical modifier is deliberately irrelevant: event flags are explicit.
        let physicallyHeld: CGEventFlags = .maskAlternate
        #expect(!physicallyHeld.isEmpty)
        await f.start("option held fixture")
        f.clock.advance(to: 1)
        #expect(f.poster.posted.count >= 2)
        #expect(f.poster.posted.allSatisfy { $0.flags.isEmpty })
        #expect(f.poster.posted.filter(\.keyDown).count * 2 == f.poster.posted.count)
        print("C2 CONTROL option_held flags_on_events=0")
    }

    @Test func surrogatePairsAndGraphemesNeverSplit() async {
        let f = Fixture()
        let text = String(repeating: "a", count: 31) + "😀e\u{301}👨‍👩‍👧‍👦🇲🇾" + String(repeating: "界", count: 40)
        await f.start(text)
        f.clock.advance(to: 2)
        let chunks = f.poster.posted.filter(\.keyDown).map { String(decoding: $0.utf16, as: UTF16.self) }
        #expect(chunks.joined() == text)
        #expect(chunks.flatMap(Array.init) == Array(text))
        #expect(f.poster.posted.allSatisfy { !$0.utf16.isEmpty && $0.utf16.count <= 32 })
        #expect(chunks.allSatisfy { !$0.contains("\u{fffd}") })
        #expect(f.result == .confirmed)
        print("C2 CONTROL surrogate_pairs split=0")
    }

    @Test func oversizedGraphemeFallsBackBeforePosting() async {
        let f = Fixture()
        let text = "e" + String(repeating: "\u{301}", count: 33)
        #expect(text.count == 1)
        await f.start(text)
        f.clock.advance(to: 1)
        #expect(f.result == .confirmed)
        #expect(f.poster.posted.isEmpty)
        #expect(f.poster.pasteCount == 1)
        #expect(f.texts == [text])
        #expect(f.logs.last == "insertion=paste reason=grapheme_too_long confirmed=1")
    }

    @Test func eventPreparationFailureFallsBackBeforePosting() async {
        let f = Fixture()
        f.poster.accepts = false
        await f.start("fixture")
        f.clock.advance(to: 1)
        #expect(f.poster.posted.isEmpty)
        #expect(f.poster.pasteCount == 1)
        #expect(f.logs.last == "insertion=paste reason=events_unavailable confirmed=1")
    }

    @Test func pasteTypesAndSnapshotRestore() async {
        let f = Fixture()
        let custom = NSPasteboard.PasteboardType("fixture.custom")
        f.pb.setData(Data([0, 1, 255]), forType: custom)
        let snapshot = PasteboardSnapshot.capture(f.pb)
        f.eligibility = .secure
        var transient = false
        var concealed = false
        f.poster.onPaste = {
            transient = f.pb.types?.contains(.init("org.nspasteboard.TransientType")) == true
            concealed = f.pb.types?.contains(.init("org.nspasteboard.ConcealedType")) == true
            f.texts = [f.pb.string(forType: .string) ?? ""]
        }
        await f.start("fixture")
        f.clock.advance(to: 1)
        #expect(transient && concealed)
        #expect(PasteboardSnapshot.capture(f.pb) == snapshot)
        print("C2 CONTROL paste_types transient=1 concealed=1 restored=1")
    }

    @Test func cancelMidTypingKeepsOnlyUnpostedRemainder() async {
        let f = Fixture()
        let text = String(repeating: "fixture ", count: 91)
        let baseline = f.pb.changeCount
        await f.start(text)
        f.clock.advance(to: 0.03)
        let count = f.poster.posted.count
        let delivered = f.typed
        #expect(count > 0)
        #expect(delivered.count < text.count)
        f.inserter.cancelTyping()
        f.clock.advance(to: 10.1)
        #expect(f.poster.posted.count == count)
        #expect(f.result == .timedOut)
        #expect(f.poster.pasteCount == 0)
        #expect(f.pb.changeCount == baseline)
        #expect(f.inserter.heldText == String(text.dropFirst(delivered.count)))
        print("C2 CONTROL cancel_mid_typing events_after_cancel=0")
    }

    @Test func focusLostDuringTypingStopsAndNeverPastes() async {
        let f = Fixture()
        await f.start(String(repeating: "fixture ", count: 91))
        f.clock.advance(to: 0.03)
        let count = f.poster.posted.count
        f.texts = nil // the fake AX reader represents the SAME destination; nil means it changed
        f.clock.advance(to: 10.1)
        #expect(f.poster.posted.count == count)
        #expect(f.poster.pasteCount == 0)
        #expect(f.result == .timedOut)
    }

    @Test(arguments: ["suffix", "unchanged", "selection", "unrelated", "clipboard"])
    func typedConfirmationRequiresCompleteNewPayload(evidence: String) async {
        let f = Fixture()
        let text = String(repeating: "fixture ", count: 91)
        f.confirmsTyping = false
        f.texts = evidence == "unchanged" ? [text] : ["initial"]
        await f.start(text)
        f.clock.advance(to: 0.5)
        switch evidence {
        case "suffix": f.texts = [String(text.suffix(48))]
        case "selection": f.texts = ["initial", text]
        case "unrelated": f.texts = [String(repeating: "x", count: text.count)]
        case "clipboard": f.pb.setString(text, forType: .string)
        default: break
        }
        f.clock.advance(to: 10)
        #expect(f.result == .timedOut)
        #expect(f.poster.pasteCount == 0)
    }

    @Test func cocoaDefaultPrefsUsesPaste() async {
        let f = Fixture()
        f.bundleID = "com.apple.TextEdit"
        // fake prefs all unset
        await f.start("fixture")
        f.clock.advance(to: 10.1)
        if f.poster.pasteCount == 0 && !f.poster.posted.isEmpty {
            print("C2B RED target=cocoa_default_prefs insertion=typed")
        } else {
            let reason = f.logs.compactMap { log -> String? in
                guard log.contains("reason=") else { return nil }
                return log.components(separatedBy: "reason=").last?.components(separatedBy: " ").first
            }.last ?? "none"
            print("C2B GREEN target=cocoa_default_prefs insertion=paste reason=\(reason) typed_events=\(f.poster.posted.count)")
        }
        #expect(f.poster.pasteCount == 1)
        #expect(f.poster.posted.isEmpty)
        #expect(f.logs.last == "insertion=paste reason=text_substitution confirmed=1")
    }

    @Test func terminalBundleAllowsTyping() async {
        let f = Fixture()
        f.bundleID = "dev.warp.Warp-Stable"
        await f.start("fixture")
        f.clock.advance(to: 10.1)
        #expect(f.result == .confirmed)
        #expect(f.poster.pasteCount == 0)
        #expect(!f.poster.posted.isEmpty)
        print("C2B CONTROL target=terminal bundle=dev.warp.Warp-Stable insertion=typed confirmed=\(f.result == .confirmed ? 1 : 0)")
    }

    @Test func cocoaAllOffAllowsTyping() async {
        let f = Fixture()
        f.bundleID = "com.apple.TextEdit"
        for key in TextSubstitutionPolicy.substitutionKeys {
            f.prefs[key] = false
        }
        await f.start("fixture")
        f.clock.advance(to: 10.1)
        #expect(f.result == .confirmed)
        #expect(f.poster.pasteCount == 0)
        #expect(!f.poster.posted.isEmpty)
        print("C2B CONTROL target=cocoa_all_off insertion=typed")
    }

    @Test func cocoaOneKeyOnUsesPaste() async {
        let f = Fixture()
        f.bundleID = "com.apple.TextEdit"
        for key in TextSubstitutionPolicy.substitutionKeys {
            f.prefs[key] = false
        }
        f.prefs["NSAutomaticQuoteSubstitutionEnabled"] = true
        await f.start("fixture")
        f.clock.advance(to: 10.1)
        #expect(f.result == .confirmed)
        #expect(f.poster.pasteCount == 1)
        #expect(f.poster.posted.isEmpty)
        #expect(f.logs.last == "insertion=paste reason=text_substitution confirmed=1")
        print("C2B CONTROL target=one_key_on key=NSAutomaticQuoteSubstitutionEnabled insertion=paste")
    }

    @Test func unknownBundleUsesPaste() async {
        let f = Fixture()
        f.bundleID = nil
        await f.start("fixture")
        f.clock.advance(to: 10.1)
        #expect(f.result == .confirmed)
        #expect(f.poster.pasteCount == 1)
        #expect(f.poster.posted.isEmpty)
        #expect(f.logs.last == "insertion=paste reason=text_substitution confirmed=1")
        print("C2B CONTROL target=unknown_bundle insertion=paste reason=text_substitution")
    }

    @Test func globalOnAppOffResolvesApp() async {
        var appPrefs: [String: [String: Bool]] = [
            "com.apple.TextEdit": [:]
        ]
        var globalPrefs: [String: Bool] = [:]
        for key in TextSubstitutionPolicy.substitutionKeys {
            appPrefs["com.apple.TextEdit"]?[key] = false
        }
        globalPrefs["NSAutomaticQuoteSubstitutionEnabled"] = true
        appPrefs["com.apple.TextEdit"]?["NSAutomaticQuoteSubstitutionEnabled"] = false

        let f = Fixture()
        f.bundleID = "com.apple.TextEdit"
        f.customReader = { key, bundleID in
            if let appVal = appPrefs[bundleID]?[key] {
                return appVal
            }
            return globalPrefs[key]
        }
        await f.start("fixture")
        f.clock.advance(to: 10.1)
        #expect(f.result == .confirmed)
        #expect(f.poster.pasteCount == 0)
        #expect(!f.poster.posted.isEmpty)
        print("C2B CONTROL global_on_app_off resolves=app")
    }
}
