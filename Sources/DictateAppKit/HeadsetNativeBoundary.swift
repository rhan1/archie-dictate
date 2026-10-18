import DictateCore
import Foundation

/// A headset conversion stage whose native call failed (an Objective-C exception caught by the
/// boundary, or a native constructor that returned nothing). Carries the stage name only.
struct HeadsetNativeFailure: Error {
    let stage: String
    let error: NSError

    static func wrap(_ error: Error) -> HeadsetNativeFailure {
        error as? HeadsetNativeFailure ?? HeadsetNativeFailure(stage: "unknown", error: error as NSError)
    }

    /// Log field: the exception's name or the error's domain:code — never audio, never text.
    var field: String {
        if let name = (error.userInfo["name"] ?? error.userInfo["exceptionName"]) as? String { return "exception=\(name)" }
        return "error=\(error.domain):\(error.code)"
    }
}

/// The headset consumers' native-call boundary (engine tap `consume`, AUHAL worker drain/start/format
/// change). Never used on the real-time HAL callback. `before`, `onFailure` and `converted` are offline
/// test seams and stay nil in production.
final class HeadsetNativeBoundary {
    /// Test seam: runs where the stage's native call runs (a forced Objective-C exception raised here
    /// is indistinguishable from one raised by the AVFoundation call itself).
    var before: ((String) -> Void)?
    /// Test seam: a stage whose native call failed, with the caught error.
    var onFailure: ((String, NSError) -> Void)?
    /// Test seam: each converted chunk the engine arm hands to arbitration (counts only, never logged).
    var converted: (([Float]) -> Void)?

    private let lock = NSLock()
    private var reported: Set<String> = []

    /// v1.17 (R4): the stage runs inside Dictate's Objective-C catching frame (`captureObjC`), so an
    /// exception becomes a `HeadsetNativeFailure` right here — inside the caller's lock or ring-slot
    /// closure, before anything unwinds through Swift frames.
    func call<T>(_ stage: String, _ operation: () throws -> T) throws -> T {
        do {
            return try captureObjC {
                before?(stage)
                return try operation()
            }
        } catch {
            throw HeadsetNativeFailure(stage: stage, error: error as NSError)
        }
    }

    /// Records a caught failure. True the first time this stage fails since the last recovered
    /// conversion: the caller notes it once (stage name only), not once per buffer.
    func failed(_ failure: HeadsetNativeFailure) -> Bool {
        onFailure?(failure.stage, failure.error)
        return lock.withLock { reported.insert(failure.stage).inserted }
    }

    /// A buffer converted after failures: true once (the caller notes the recovery), later failures report again.
    func recovered() -> Bool {
        lock.withLock {
            guard !reported.isEmpty else { return false }
            reported.removeAll()
            return true
        }
    }
}
