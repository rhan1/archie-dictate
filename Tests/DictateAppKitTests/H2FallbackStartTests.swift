import AVFoundation
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

@Suite(.serialized)
struct H2FallbackStartTests {
    /// All native operations are closures. No engine, device lookup, sleep or home-path IO.
    final class Fixture {
        let recorder = C1VoiceProcessingTests().recorder()
        let clock = H1VoiceProcessingFallbackTests.Clock()
        var selector = CaptureBuiltInSelector(legacySingleAttempt: true)
        var selects = 0
        var starts = 0
        var frames = 0
        var events: [String] = []
        var notes: [String] = []

        func make(_ mode: CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit {
            events.append("make_\(mode.rawValue)")
            return CaptureInputUnit(start: {
                if mode == .halout {
                    try self.selector.run(select: {
                        self.selects += 1
                        if self.selects == 1 {
                            throw NSError(domain: NSOSStatusErrorDomain, code: 560227702)
                        }
                    }, note: { self.notes.append($0) })
                }
                self.starts += 1
            }, dispose: { self.events.append("dispose_vpio") }, hardwareChannels: { 9 })
        }
    }

    @Test func legacySingleSelectFailsAfterMultichannelRefusal() throws {
        let f = Fixture()
        defer { _ = f.recorder.stop() }
        var caught: NSError?
        do { try f.recorder.offlineStartInput(at: 0, make: f.make) }
        catch { caught = error as NSError }
        try #require(caught?.domain == NSOSStatusErrorDomain && caught?.code == 560227702)
        try #require(f.recorder.stats.voiceProcessing == "fallback")
        try #require(f.events == ["make_vpio", "dispose_vpio", "make_halout"])
        try #require(f.selects == 1 && f.starts == 0 && f.frames == 0)
        try #require(f.recorder.stats.ioOps.hasPrefix("io_ops=start:0"))
        print("H2 RED fallback=multichannel_input select_err=!dev outcome=mic_start frames=0")
    }
}
