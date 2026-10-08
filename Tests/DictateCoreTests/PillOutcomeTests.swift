import Testing
import DictateCore

@Suite("PillOutcome")
struct PillOutcomeTests {
    @Test func heldPersistsPastOneAndAHalfSeconds() {
        var pill = PillOutcome(.held("focus_changed"), hasText: true)
        #expect(pill.handle(.tick(elapsed: 1.6)).label == "held")
        #expect(pill.handle(.tick(elapsed: 19.999)).label == "held")
    }
    @Test func errorPersists() {
        var pill = PillOutcome(.error("empty_transcript"))
        #expect(pill.handle(.tick(elapsed: 19)).label == "error")
    }
    @Test(arguments: [PillOutcome.Kind.held("focus_changed"), .error("missing_key")])
    func autoDismissAtTwentySeconds(kind: PillOutcome.Kind) {
        var pill = PillOutcome(kind, hasText: true)
        #expect(pill.handle(.tick(elapsed: 20)).label == nil)
        #expect(!pill.handle(.recoverTap).pasteHeldText)
    }
    @Test(arguments: [PillOutcome.Event.dismissTap, .escape])
    func dismissWithoutPaste(event: PillOutcome.Event) {
        var pill = PillOutcome(.held("focus_changed"), hasText: true)
        let output = pill.handle(event)
        #expect(output.label == nil)
        #expect(!output.pasteHeldText)
        #expect(!pill.handle(.recoverTap).pasteHeldText)
    }
    @Test(arguments: [PillOutcome.Event.recoverTap, .singleOptionTap])
    func recoverExactlyOnce(event: PillOutcome.Event) {
        var pill = PillOutcome(.held("focus_changed"), hasText: true)
        #expect(pill.handle(event).pasteHeldText)
        #expect(!pill.handle(.recoverTap).pasteHeldText)
        #expect(pill.label == nil)
    }
    @Test func errorTextCanRecover() {
        var pill = PillOutcome(.error("network_timedOut"), hasText: true)
        #expect(pill.handle(.recoverTap).pasteHeldText)
        #expect(!pill.handle(.recoverTap).pasteHeldText)
    }
    @Test(arguments: [PillOutcome.Kind.held("no_stt"), .error("empty_transcript")])
    func noTextDoesNotPaste(kind: PillOutcome.Kind) {
        var pill = PillOutcome(kind)
        let originalLabel = pill.label
        #expect(!pill.handle(.recoverTap).pasteHeldText)
        #expect(pill.label == originalLabel)
    }
    @Test func rawHidesAtOneAndAHalfSeconds() {
        var pill = PillOutcome(.rawPasted("network_timedOut"), hasText: true)
        #expect(pill.handle(.tick(elapsed: 1.499)).label == "raw")
        #expect(!pill.handle(.recoverTap).pasteHeldText)
        #expect(pill.handle(.tick(elapsed: 1.5)).label == nil)
    }
    @Test func okHidesImmediately() {
        var pill = PillOutcome(.ok, hasText: true)
        #expect(pill.label == nil)
        #expect(!pill.handle(.recoverTap).pasteHeldText)
    }
    @Test func labels() {
        for (kind, label) in [(PillOutcome.Kind.held("focus_changed"), "held"), (.held("no_stt"), "no speech"),
                              (.error("missing_key"), "no key"), (.error("network_timedOut"), "timeout"),
                              (.error("cannotConnectToHost"), "offline"), (.error("not connected"), "offline"),
                              (.error("notConnectedToInternet"), "offline"), (.error("network_-1004"), "offline"),
                              (.error("network_-1009"), "offline"), (.error("empty_transcript"), "error"),
                              (.rawPasted("rejected:ratio"), "raw")] {
            #expect(PillOutcome(kind).label == label)
        }
    }
}
