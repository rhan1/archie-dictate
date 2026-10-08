import Foundation
import Testing
@testable import DictateCore

/// Scripted socket: records sent frames; `receive()` replays queued frames
/// and then parks until closed.
final class FakeSocket: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [String] = []
    private var inbox: [String]
    var connectError: Error?
    var connectDelay: TimeInterval = 0

    init(inbox: [String] = [#"{"type":"session.created"}"#]) { self.inbox = inbox }

    func connect(url: URL, headers: [String: String]) async throws {
        if connectDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(connectDelay * 1_000_000_000)) }
        if let connectError { throw connectError }
    }
    func send(text: String) async throws { lock.withLock { sent.append(text) } }
    func receive() async throws -> String {
        while true {
            if let next = lock.withLock({ inbox.isEmpty ? nil : inbox.removeFirst() }) { return next }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    func close() {}
    var frames: [String] { lock.withLock { sent } }
}

private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
}

private let speech = [Int16](repeating: 8_000, count: 2_400)   // 100 ms, loud
private let quiet = [Int16](repeating: 0, count: 2_400)        // 100 ms, silent

@Suite("Realtime")
struct RealtimeTests {
    @Test func sessionUpdateShape() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(RealtimeTranscriber.sessionUpdate().utf8)) as? [String: Any])
        #expect(json["type"] as? String == "session.update")
        let session = try #require(json["session"] as? [String: Any])
        #expect(session["type"] as? String == "transcription")
        let input = try #require((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        #expect(input["turn_detection"] is NSNull)
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-4o-transcribe")
        #expect(transcription["prompt"] == nil)   // the model echoed it back live (00:27)
        #expect(transcription["language"] as? String == "en")
    }

    @Test func appendFrameIsLittleEndianBase64() {
        let frame = RealtimeTranscriber.appendFrame([1, -2])
        #expect(frame == #"{"type":"input_audio_buffer.append","audio":"AQD+/w=="}"#)
    }

    @Test func framesKeepOrderAndFinishJoinsSegments() async throws {
        let socket = FakeSocket()
        let rt = RealtimeTranscriber(transport: socket, apiKey: { "k" })
        // Audio queued BEFORE the socket opens must still be sent, in order, after session.update.
        rt.append(speech)
        try await rt.open()
        for _ in 0..<12 { rt.append(speech) }
        for _ in 0..<3 { rt.append(quiet) }          // pause -> segment commit
        for _ in 0..<5 { rt.append(speech) }
        await waitUntil { socket.frames.filter { $0 == RealtimeTranscriber.commitFrame }.count == 1 }
        let finishing = Task { try await rt.finish(timeout: 2) }
        await waitUntil { socket.frames.filter { $0 == RealtimeTranscriber.commitFrame }.count == 2 }
        let frames = socket.frames
        #expect(frames.first?.contains(#""type":"session.update""#) == true)
        #expect(frames.filter { $0.contains("input_audio_buffer.append") }.count == 21)
        // Completed events arrive out of order; text follows COMMIT order.
        rt.handle(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#)
        rt.handle(#"{"type":"input_audio_buffer.committed","item_id":"b"}"#)
        rt.handle(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":" second part. "}"#)
        rt.handle(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"First part,"}"#)
        #expect(try await finishing.value == "First part, second part.")
        #expect(rt.segmentCount == 2)
    }

    @Test func quietTailIsNotCommitted() async throws {
        let socket = FakeSocket()
        let rt = RealtimeTranscriber(transport: socket, apiKey: { "k" })
        try await rt.open()
        for _ in 0..<12 { rt.append(speech) }
        for _ in 0..<5 { rt.append(quiet) }          // segment commit, then a silent tail
        let finishing = Task { try await rt.finish(timeout: 2) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(socket.frames.filter { $0 == RealtimeTranscriber.commitFrame }.count == 1)
        rt.handle(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#)
        rt.handle(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Only this."}"#)
        #expect(try await finishing.value == "Only this.")
    }

    @Test func serverErrorFailsFinish() async throws {
        let socket = FakeSocket()
        let rt = RealtimeTranscriber(transport: socket, apiKey: { "k" })
        try await rt.open()
        rt.append(speech)
        let finishing = Task { try await rt.finish(timeout: 2) }
        try await Task.sleep(nanoseconds: 50_000_000)
        rt.handle(#"{"type":"error","error":{"code":"rate_limit_exceeded","message":"x"}}"#)
        await #expect(throws: RealtimeError.server("rate_limit_exceeded")) { try await finishing.value }
    }

    @Test func openTimesOutWhenHandshakeIsSlow() async {
        let socket = FakeSocket()
        socket.connectDelay = 0.5
        let rt = RealtimeTranscriber(transport: socket, apiKey: { "k" })
        await #expect(throws: RealtimeError.timeout) { try await rt.open(timeout: 0.1) }
        #expect(rt.hasFailed)
    }

    @Test func openRejectsUnexpectedFirstFrame() async {
        let socket = FakeSocket(inbox: [#"{"type":"error","error":{"code":"invalid_api_key"}}"#])
        let rt = RealtimeTranscriber(transport: socket, apiKey: { "k" })
        await #expect(throws: RealtimeError.connect("error")) { try await rt.open() }
    }

    @Test func missingKeyFailsOpen() async {
        let rt = RealtimeTranscriber(transport: FakeSocket(), apiKey: { throw TranscriptionError.missingKey })
        await #expect(throws: RealtimeError.missingKey) { try await rt.open() }
    }

    @Test func finishTimesOutWithoutCompletion() async throws {
        let rt = RealtimeTranscriber(transport: FakeSocket(), apiKey: { "k" })
        try await rt.open()
        rt.append(speech)
        await #expect(throws: RealtimeError.timeout) { try await rt.finish(timeout: 0.1) }
    }
}

@Suite("PauseSegmenter")
struct PauseSegmenterTests {
    @Test func commitsOnlyAfterSpeechThenPause() {
        var s = PauseSegmenter()
        var commits = 0
        for _ in 0..<12 { if s.shouldCommit(after: speech) { commits += 1 } }
        #expect(commits == 0)
        #expect(s.shouldCommit(after: quiet) == false)   // 100 ms quiet
        #expect(s.shouldCommit(after: quiet) == true)    // 200 ms quiet -> commit
        #expect(s.hasUncommittedSpeech == false)
        for _ in 0..<10 { #expect(s.shouldCommit(after: quiet) == false) }   // silence alone never commits
    }

    @Test func shortUtteranceWaitsForMinimumSegment() {
        var s = PauseSegmenter()
        for _ in 0..<3 { _ = s.shouldCommit(after: speech) }   // 300 ms speech
        #expect(s.shouldCommit(after: quiet) == false)
        #expect(s.shouldCommit(after: quiet) == false)          // 500 ms total < 1 s
        #expect(s.hasUncommittedSpeech)
    }

    @Test func noisyHeadsetDipCountsAsQuietRelativeToSpeech() {
        var s = PauseSegmenter()
        let loud = [Int16](repeating: 8_000, count: 2_400)     // ~ -12 dBFS speech
        let floor = [Int16](repeating: 1_000, count: 2_400)    // ~ -30 dBFS headset floor: NOT under -40 dBFS
        for _ in 0..<12 { _ = s.shouldCommit(after: loud) }
        #expect(s.shouldCommit(after: floor) == false)
        #expect(s.shouldCommit(after: floor) == true)           // 200 ms of relative quiet
    }

    @Test func longSegmentCommitsOnAHundredMillisecondDip() {
        var s = PauseSegmenter()
        for _ in 0..<31 { _ = s.shouldCommit(after: speech) }  // 3.1 s fluent speech
        #expect(s.shouldCommit(after: quiet) == true)           // one 100 ms dip is enough now
    }

    @Test func disabledNeverCommits() {
        var s = PauseSegmenter(enabled: false)
        for _ in 0..<12 { _ = s.shouldCommit(after: speech) }
        for _ in 0..<5 { #expect(s.shouldCommit(after: quiet) == false) }
    }
}

@Suite("PromptEcho")
struct PromptEchoTests {
    let vocab = "Limpar, TurnoutWatch, Raza, Politrace, GrantWatch, DB99, Archie, Jarvis, Codex, agy, Warp, Claude, Fable, Opus, Sonnet"

    @Test func verbatimEchoIsCaught() {
        #expect(PromptEcho.isEcho(vocab, vocabulary: vocab))
        #expect(PromptEcho.isEcho("Limpar, TurnoutWatch, Raza, Politrace, GrantWatch, DB99, Archie, Jarvis, Codex, agy, Warp, Claude, Fable, Opus, Sonnet.", vocabulary: vocab))
    }

    @Test func partialEchoOverSixtyPercentIsCaught() {
        // 10 of 15 terms (67 %)
        #expect(PromptEcho.isEcho("Limpar TurnoutWatch Raza Politrace GrantWatch DB99 Archie Jarvis Codex agy", vocabulary: vocab))
    }

    @Test func realDictationMentioningSomeTermsPasses() {
        #expect(!PromptEcho.isEcho("Ask Archie and Jarvis whether the Limpar and Politrace runs finished, then ping Raza.", vocabulary: vocab))
        #expect(!PromptEcho.isEcho("Send it Wednesday.", vocabulary: vocab))
        #expect(!PromptEcho.isEcho("anything", vocabulary: ""))
    }
}

