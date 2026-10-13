import Foundation
import DictateCore
// TEMPORARY (v10 manager): replaced by W3's HeadsetCaptureUnit.swift at merge.
final class HeadsetCaptureUnit: HeadsetCapture {
    var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
    var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)?
    func start(deviceUID: String, epoch: CaptureEpoch) throws { throw CancellationError() }
    func stop() {}
    func stop(epoch: CaptureEpoch) {}
    var isRunning: Bool { false }
    var lastCallbackTime: TimeInterval? { nil }
    var formatGeneration: Int { 0 }
    var counters: SourceCounters { SourceCounters() }
    let backend = "auhal"
}
