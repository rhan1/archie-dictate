import Foundation
import Testing

@Suite("BtProofGate")
struct BtProofGateTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/DictateCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <repo root>
    }

    private func runGate(fixturePath: String) throws -> (status: Int32, finalLine: String, output: String) {
        let scriptURL = Self.repoRoot.appendingPathComponent("tools/bt-proof.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "--from-file", fixturePath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        let lines = output.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let finalLine = lines.last ?? ""
        return (process.terminationStatus, finalLine, output)
    }

    private func fixtureURL(named name: String) -> String {
        Self.repoRoot.appendingPathComponent("tools/fixtures/bt-proof").appendingPathComponent(name).path
    }

    @Test func greenFallbackPasses() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-fallback.log"))
        #expect(res.status == 0)
        #expect(res.finalLine == "BT-PROOF: PASS")
        #expect(res.output.contains("-> fallback"))
    }

    @Test func greenTransportPasses() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-transport.log"))
        #expect(res.status == 0)
        #expect(res.finalLine == "BT-PROOF: PASS")
        #expect(res.output.contains("-> recovered"))
    }

    @Test func greenHeldPassesAsHeld() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-held.log"))
        #expect(res.status == 0)
        #expect(res.finalLine == "BT-PROOF: PASS")
        #expect(res.output.contains(" HELD "))
    }

    @Test func red2133Fails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-2133.log"))
        #expect(res.status == 1)
        #expect(res.finalLine == "BT-PROOF: FAIL outcome=error:silence missing_capture_intervals coverage=0.8% <95% missing_speech_sections drop_unrecovered@21:33:11.381 drop_unrecovered@21:33:11.392 successful_fallbacks=0")
        #expect(res.output.contains("successful_fallbacks=0"))
    }

    @Test func redDeadFallbackFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-dead-fallback.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("drop_unrecovered@"))
    }

    @Test func redFallbackZeroSectionsFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-fallback-zero-sections.log"))
        #expect(res.status == 1)
        #expect(res.finalLine == "BT-PROOF: FAIL speech_sections=0 <3")
    }

    /// v1.10 L2: the live v1.9 R3 notes (c35bde97) — the defect L2 fixes, still a FAIL as recorded.
    @Test func redV19R3ZeroSectionsFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-v19-r3-zero-sections.log"))
        #expect(res.status == 1)
        #expect(res.finalLine == "BT-PROOF: FAIL speech_sections=0 <3")
    }

    @Test func redMissingOutcomeFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-missing-outcome.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("missing_outcome"))
    }

    @Test func redDuplicateSessionFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-duplicate-session.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("duplicate_session"))
    }

    @Test func redLateCreationFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-late-creation.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("drop_unrecovered@"))
    }

    @Test func redFullZerosFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-full-zeros.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("outcome=error:mic_dead"))
        #expect(res.finalLine.contains("speech_sections=0 <3"))
    }

    @Test func redClickOnlyFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-click-only.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("speech_sections=1 <3"))
    }

    @Test func redDuplicatedFramesFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-duplicated-frames.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("duplicate_or_unordered_intervals"))
    }

    @Test func redMissingEndFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-missing-end.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("missing_end_marker"))
    }

    @Test func redGapFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-gap.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("gap=1000ms >600ms"))
    }

    @Test func redLowCoverageFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-low-coverage.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("coverage="))
        #expect(res.finalLine.contains("<95%"))
    }

    @Test func redEmptyFixtureFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-empty.log"))
        #expect(res.status == 1)
        #expect(res.finalLine == "BT-PROOF: FAIL missing_sessions")
    }

    @Test func devNullFailsMissingSessions() throws {
        let res = try runGate(fixturePath: "/dev/null")
        #expect(res.status == 1)
        #expect(res.finalLine == "BT-PROOF: FAIL missing_sessions")
    }

    // MARK: - v1.11 L5 bt-proof honesty tests

    @Test func redLateSignalFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-late-signal.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("drop_unrecovered@"))
    }

    @Test func redLateFallbackFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-late-fallback.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("drop_unrecovered@"))
    }

    @Test func redTruncatedIntervalsFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-truncated-intervals.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("truncated_intervals"))
    }

    @Test func redOverlappingSessionsFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-overlapping-sessions.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("ambiguous_session"))
    }

    @Test func greenBoundedRecoveryPasses() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-bounded-recovery.log"))
        #expect(res.status == 0)
        #expect(res.finalLine == "BT-PROOF: PASS")
        #expect(res.output.contains("DROPS_SEEN=1"))
        #expect(res.output.contains("RECOVERED=1"))
        #expect(res.output.contains("VERDICT headset=PASS"))
    }

    @Test func greenHeadsetCarriedPasses() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-headset-carried.log"))
        #expect(res.status == 0)
        #expect(res.finalLine == "BT-PROOF: PASS")
        #expect(res.output.contains("VERDICT headset=PASS"))
    }

    @Test func positiveControlDropCounterNonzero() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-bounded-recovery.log"))
        #expect(res.status == 0)
        #expect(res.finalLine == "BT-PROOF: PASS")
        let dropsSeen = res.output.split(separator: "\n")
            .compactMap { line -> Int? in
                guard line.contains("DROPS_SEEN=") else { return nil }
                if let match = line.range(of: "DROPS_SEEN=") {
                    let rest = line[match.upperBound...]
                    let numStr = rest.prefix(while: { $0.isNumber })
                    return Int(numStr)
                }
                return nil
            }.first ?? 0
        #expect(dropsSeen >= 1)
    }

    @Test func separateVerdictsFormatted() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-bounded-recovery.log"))
        #expect(res.status == 0)
        #expect(res.output.contains("VERDICT continuity=PASS"))
        #expect(res.output.contains("VERDICT headset=PASS"))
        #expect(res.output.contains("VERDICT content=PASS"))
        #expect(res.output.contains("VERDICT playback=NA"))
    }

    // MARK: - v1.13 L1 bt-proof pause gating tests

    @Test func greenPausePeaksPass() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-pause-kept.log"))
        #expect(res.status == 0)
        #expect(res.finalLine == "BT-PROOF: PASS")
        #expect(res.output.contains("PEAKS_SEEN=1"))
        #expect(res.output.contains("VERDICT pause=PASS"))
        #expect(res.output.contains("SWITCH session=41f98dbd to=headset reason=takeover"))
    }

    @Test func redPauseSwitchFails() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "red-pause-switch.log"))
        #expect(res.status == 1)
        #expect(res.finalLine.contains("pause_switch@"))
    }

    @Test func legacyLogPauseVerdictNA() throws {
        let res = try runGate(fixturePath: fixtureURL(named: "green-headset-carried.log"))
        #expect(res.status == 0)
        #expect(res.output.contains("PEAKS_SEEN=0"))
        #expect(res.output.contains("VERDICT pause=NA"))
    }
}

