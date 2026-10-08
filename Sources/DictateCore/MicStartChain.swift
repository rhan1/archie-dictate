import Foundation
import DictateObjC

/// Convert Objective-C exceptions at the narrow call boundary; Swift errors
/// retain their original domain/code. Core stays free of AVFoundation/AppKit.
public func captureObjC<T>(_ operation: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    var exception: NSError?
    let returned = DictateTryObjC({ result = Result { try operation() } }, &exception)
    guard returned else { throw exception ?? NSError(domain: "DictateObjC", code: 1) }
    return try result!.get()
}

public struct MicStartChain {
    public enum Step: Equatable { case initial, retry, builtIn, done, failed }
    public private(set) var step: Step = .initial
    public var device: MicChoice { step == .builtIn ? .builtIn : .default }
    public var needsRebuild: Bool { step == .retry || step == .builtIn }
    public var delay: TimeInterval { step == .retry ? 0.3 : 0 }
    public var isAttempt: Bool { step != .done && step != .failed }
    public init() {}

    public mutating func failed(_ error: Error) -> [String] {
        let error = error as NSError
        var fields = ["mic_error=\(error.domain):\(error.code) \(error.localizedDescription)"]
        switch step {
        case .initial: step = .retry
        case .retry: fields.append("mic_retry=fail"); step = .builtIn
        case .builtIn: step = .failed
        default: break
        }
        return fields
    }
    public mutating func succeeded() -> [String] {
        let fields: [String]
        switch step {
        case .retry: fields = ["mic_retry=ok"]
        case .builtIn: fields = ["mic_fallback=builtin"]
        default: fields = []
        }
        step = .done
        return fields
    }
}
