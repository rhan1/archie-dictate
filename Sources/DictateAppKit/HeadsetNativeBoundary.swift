import AVFoundation
import Foundation

/// Per-consumer seam; inert in production. Never used on the real-time HAL callback.
final class HeadsetNativeBoundary {
    var before: ((String) -> Void)?
    var onFailure: ((String, NSError) -> Void)?
    func call<T>(_ stage: String, _ operation: () throws -> T) throws -> T {
        before?(stage)
        return try operation()
    }
    func failed(_ stage: String, _ error: Error) {
        onFailure?(stage, error as NSError)
    }
}
