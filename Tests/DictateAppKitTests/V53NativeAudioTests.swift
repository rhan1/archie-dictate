import AVFoundation
import Foundation
import DictateObjC
import Testing
@testable import DictateAppKit

struct V53NativeAudioTests {
    @Test func constructorsAndConversionRetainNativeFailureAndRecover() throws {
        for rate in [0.0, -1, Double.nan] {
            #expect(throws: (any Error).self) { try NativePCM.format(.pcmFormatFloat32, rate: rate, channels: 1, interleaved: false) }
        }
        let stereo = try NativePCM.format(.pcmFormatFloat32, rate: 24_000, channels: 2, interleaved: false)
        let mono = try NativePCM.format(.pcmFormatFloat32, rate: 16_000, channels: 1, interleaved: false)
        #expect(throws: (any Error).self) { try NativePCM.buffer(stereo, capacity: 0) }
        let source = try NativePCM.buffer(stereo, capacity: 2400)
        source.frameLength = 2400
        for c in 0..<2 { for i in 0..<2400 { source.floatChannelData![c][i] = 0.1 } }
        let output = try NativePCM.buffer(mono, capacity: 2000)
        let broken = dictate_throwing_converter(stereo, mono)
        do {
            _ = try NativePCM.convert(broken, to: output) { _, status in status.pointee = .endOfStream; return nil }
            Issue.record("forced native exception must fail")
        } catch {
            #expect((error as NSError).userInfo["exceptionName"] as? String == "DictateForcedConvert")
            print("R0 DICTATE_NATIVE forced=DictateForcedConvert alive=1")
        }
        let converter = try NativePCM.converter(from: stereo, to: mono)
        var supplied = false
        _ = try NativePCM.convert(converter, to: output) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        #expect(output.frameLength > 1500)
        #expect(output.floatChannelData![0][100] > 0)
        print("R0 DICTATE_NATIVE subsequent_frames=\(output.frameLength) nonzero=1")
        let wrong = try NativePCM.buffer(stereo, capacity: 1600)
        let mismatched = try NativePCM.converter(from: stereo, to: mono)
        do {
            _ = try NativePCM.convert(mismatched, to: wrong) { _, status in status.pointee = .endOfStream; return nil }
            Issue.record("mismatched converter input must fail")
        } catch { #expect((error as NSError).domain == NSOSStatusErrorDomain) }
    }
}
