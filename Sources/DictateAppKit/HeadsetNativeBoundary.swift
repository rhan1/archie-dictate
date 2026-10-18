import Foundation

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

    /// v1.16 behaviour: the native call runs raw — an Objective-C exception is not caught.
    func call<T>(_ stage: String, _ operation: () -> T) -> T {
        before?(stage)
        return operation()
    }
}
