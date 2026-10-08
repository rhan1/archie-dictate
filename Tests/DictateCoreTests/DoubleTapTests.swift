import Foundation
import Testing
import DictateCore

private func press(_ time: TimeInterval) -> KeyEvent {
    .flagsChanged(keyCode: 58, flags: 0x80000 | 0x20, time: time)
}
private func release(_ time: TimeInterval) -> KeyEvent {
    .flagsChanged(keyCode: 58, flags: 0, time: time)
}

@Suite("DoubleTap")
struct DoubleTapTests {
    private func results(_ events: [KeyEvent]) -> [Bool] {
        var detector = DoubleTapDetector()
        return events.map { detector.handle($0) }
    }

    @Test func twoTapsAt300Milliseconds() {
        #expect(results([press(0), release(0.05), press(0.35), release(0.40)]) == [false, false, false, true])
    }
    @Test func gapAt400Milliseconds() {
        #expect(results([press(0), release(0.05), press(0.45), release(0.50)]) == [false, false, false, false])
    }
    @Test func thirdTapStartsNewPair() {
        #expect(results([press(0), release(0.05), press(0.15), release(0.20),
                         press(0.30), release(0.35), press(0.45), release(0.50)]) ==
                [false, false, false, true, false, false, false, true])
    }
    @Test func keyDownDuringHoldInvalidatesTap() {
        #expect(results([press(0), .keyDown(keyCode: 0, time: 0.02), release(0.05),
                         press(0.15), release(0.20)]) == [false, false, false, false, false])
    }
    @Test func rightOptionNeverFires() {
        #expect(results([
            .flagsChanged(keyCode: 61, flags: 0x80000 | 0x40, time: 0),
            .flagsChanged(keyCode: 61, flags: 0, time: 0.05),
            .flagsChanged(keyCode: 61, flags: 0x80000 | 0x40, time: 0.15),
            .flagsChanged(keyCode: 61, flags: 0, time: 0.20)
        ]) == [false, false, false, false])
    }
    @Test func longHoldInvalidatesTap() {
        #expect(results([press(0), release(0.60), press(0.70), release(0.75)]) == [false, false, false, false])
    }
    @Test func commandChordInvalidatesTap() {
        #expect(results([
            .flagsChanged(keyCode: 58, flags: 0x80000 | 0x20 | 0x100000, time: 0),
            release(0.05), press(0.15), release(0.20)
        ]) == [false, false, false, false])
    }
    @Test func singleTapNeverFires() {
        #expect(results([press(0), release(0.05)]) == [false, false])
    }
    @Test func defaultWindow() {
        #expect(DoubleTapDetector.defaultWindow == 0.35)
        #expect(DoubleTapDetector.defaultMaxHold == 0.35)
    }
    @Test func slowSecondTapBecomesFirstTap() {
        #expect(results([press(0), release(0.05), press(0.55), release(0.60),
                         press(0.80), release(0.85)]) == [false, false, false, false, false, true])
    }
    @Test func keyDownBetweenTapsDiscardsFirst() {
        #expect(results([press(0), release(0.05), .keyDown(keyCode: 53, time: 0.10),
                         press(0.15), release(0.20)]) == [false, false, false, false, false])
    }
    @Test func otherFlagsChangeBetweenTapsDiscardsFirst() {
        #expect(results([press(0), release(0.05),
                         .flagsChanged(keyCode: 61, flags: 0x40, time: 0.10),
                         press(0.15), release(0.20)]) == [false, false, false, false, false])
    }
    @Test func otherFlagsChangeDuringTapInvalidatesIt() {
        #expect(results([press(0), .flagsChanged(keyCode: 56, flags: 0x20000, time: 0.02),
                         release(0.05), press(0.15), release(0.20)]) == [false, false, false, false, false])
    }
    @Test func repeatedPressInvalidatesTap() {
        #expect(results([press(0), press(0.02), release(0.05), press(0.15), release(0.20)]) ==
                [false, false, false, false, false])
    }
    @Test func forbiddenReleaseClearsPendingFirst() {
        #expect(results([press(0), release(0.05), press(0.15),
                         .flagsChanged(keyCode: 58, flags: 0x20000, time: 0.20),
                         press(0.30), release(0.35)]) == [false, false, false, false, false, false])
    }
    @Test func allForbiddenModifiersInvalidatePress() {
        for mask: UInt64 in [0x20000, 0x40000, 0x100000, 0x800000] {
            #expect(results([.flagsChanged(keyCode: 58, flags: 0x80020 | mask, time: 0),
                             release(0.05), press(0.15), release(0.20)]) == [false, false, false, false])
        }
    }
    @Test func resetDiscardsPendingFirst() {
        var detector = DoubleTapDetector()
        let firstTap = [detector.handle(press(0)), detector.handle(release(0.05))]
        #expect(firstTap == [false, false])
        detector.reset()
        let secondTap = [detector.handle(press(0.15)), detector.handle(release(0.20))]
        #expect(secondTap == [false, false])
    }
    @Test func inclusiveCustomLimits() {
        var detector = DoubleTapDetector(window: 0.5, maxHold: 0.25)
        let actual = [press(0), release(0.25), press(0.75), release(1)].map { detector.handle($0) }
        #expect(actual == [false, false, false, true])
    }
}

@Suite("DictationStateMachine")
struct DictationStateMachineTests {
    @Test func idleDoubleTapStartsRecording() {
        var machine = DictationStateMachine()
        #expect(machine.state == .idle)
        #expect(machine.doubleTap() == .startRecording)
        #expect(machine.state == .recording)
    }
    @Test func recordingDoubleTapFinishesRecording() {
        var machine = DictationStateMachine()
        _ = machine.doubleTap()
        #expect(machine.doubleTap() == .finishRecording)
        #expect(machine.state == .transcribing)
    }
    @Test func transcribingIgnoresDoubleTap() {
        var machine = DictationStateMachine()
        _ = machine.doubleTap()
        _ = machine.doubleTap()
        #expect(machine.doubleTap() == .none)
        #expect(machine.state == .transcribing)
    }
    @Test func cancelRecording() {
        var machine = DictationStateMachine()
        _ = machine.doubleTap()
        #expect(machine.cancel() == .cancelRecording)
        #expect(machine.state == .idle)
    }
    @Test func idleFinishDoesNothing() {
        var machine = DictationStateMachine()
        #expect(machine.finishButton() == .none)
        #expect(machine.state == .idle)
    }
    @Test func completedTranscriptionReturnsToIdle() {
        var machine = DictationStateMachine()
        _ = machine.doubleTap()
        _ = machine.finishButton()
        machine.transcriptionFinished()
        #expect(machine.state == .idle)
    }
    @Test func finishButtonAndDurationCap() {
        var machine = DictationStateMachine()
        #expect(machine.maxDurationReached() == .none)
        _ = machine.doubleTap()
        #expect(machine.maxDurationReached() == .finishRecording)
        #expect(machine.state == .transcribing)
        #expect(machine.finishButton() == .none)
        #expect(machine.maxDurationReached() == .none)
        #expect(DictationLimits.maxDuration == 300)
    }
    @Test func cancelTranscribingAndIdle() {
        var machine = DictationStateMachine()
        #expect(machine.cancel() == .none)
        _ = machine.doubleTap()
        _ = machine.finishButton()
        #expect(machine.cancel() == .cancelRecording)
        #expect(machine.state == .idle)
    }
    @Test func transcriptionCompletionIsOtherwiseNoOp() {
        var machine = DictationStateMachine()
        machine.transcriptionFinished()
        #expect(machine.state == .idle)
        _ = machine.doubleTap()
        machine.transcriptionFinished()
        #expect(machine.state == .recording)
    }
}

/// v1.1 A2: ⌥⌥ starts, ONE clean ⌥ tap finishes.
@Suite("SingleTapFinish")
struct SingleTapFinishTests {
    private func run(_ events: [KeyEvent], machine: inout DictationStateMachine, detector: inout DoubleTapDetector) -> [DictationAction] {
        events.map { machine.handle(detector.process($0)) }.filter { $0 != .none }
    }

    @Test func doubleTapStartsThenSingleTapFinishes() {
        var machine = DictationStateMachine()
        var detector = DoubleTapDetector()
        let start = run([press(0), release(0.05), press(0.2), release(0.25)], machine: &machine, detector: &detector)
        #expect(start == [.startRecording])
        let finish = run([press(4.0), release(4.06)], machine: &machine, detector: &detector)
        #expect(finish == [.finishRecording])
        #expect(machine.state == .transcribing)
    }

    @Test func singleTapWhileIdleDoesNothing() {
        var machine = DictationStateMachine()
        var detector = DoubleTapDetector()
        #expect(run([press(0), release(0.05)], machine: &machine, detector: &detector).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func chordWhileRecordingIsIgnored() {
        var machine = DictationStateMachine()
        var detector = DoubleTapDetector()
        _ = run([press(0), release(0.05), press(0.2), release(0.25)], machine: &machine, detector: &detector)
        // ⌥← word-jump while recording: Option down, an arrow key, Option up.
        let chord = run([press(3.0), .keyDown(keyCode: 123, time: 3.1), release(3.2)], machine: &machine, detector: &detector)
        #expect(chord.isEmpty)
        #expect(machine.state == .recording)
    }

    @Test func heldOptionWhileRecordingIsIgnored() {
        var machine = DictationStateMachine()
        var detector = DoubleTapDetector()
        _ = run([press(0), release(0.05), press(0.2), release(0.25)], machine: &machine, detector: &detector)
        #expect(run([press(3.0), release(3.8)], machine: &machine, detector: &detector).isEmpty)
        #expect(machine.state == .recording)
    }

    @Test func detectorReportsTapThenDoubleTap() {
        var detector = DoubleTapDetector()
        #expect(detector.process(press(0)) == .none)
        #expect(detector.process(release(0.05)) == .tap)
        #expect(detector.process(press(0.2)) == .none)
        #expect(detector.process(release(0.25)) == .doubleTap)
        #expect(detector.process(press(1.0)) == .none)
        #expect(detector.process(release(1.05)) == .tap)
    }
}
