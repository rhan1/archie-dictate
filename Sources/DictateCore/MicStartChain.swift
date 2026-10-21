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

/// Input-node format check before the tap is installed. After the built-in mic is
/// selected on a fresh engine, AUHAL keeps the previous default device's client
/// format (e.g. 44.1 kHz headset vs 48 kHz built-in) and its input element does
/// no sample-rate conversion; a rebuild re-creates the same stale pair (D-a:
/// `builtin_start_failed`, RecorderError.noInput). Align the client format to
/// the hardware first; rebuild at most once.
public enum TapFormatPlan {
    public struct Format: Equatable, Sendable, CustomStringConvertible {
        public var sampleRate: Double
        public var channels: UInt32
        public init(sampleRate: Double, channels: UInt32) { self.sampleRate = sampleRate; self.channels = channels }
        public var isValid: Bool { sampleRate > 0 && channels > 0 }
        public var description: String { "\(Int(sampleRate))Hz/\(channels)ch" }
    }
    public enum Outcome: Equatable, Sendable { case ready(aligned: Bool, rebuilt: Bool) }
    public struct Mismatch: Error, Equatable, CustomStringConvertible, LocalizedError {
        public let hardware: Format
        public let output: Format
        public init(hardware: Format, output: Format) { self.hardware = hardware; self.output = output }
        public var description: String { "format_mismatch hw=\(hardware) out=\(output)" }
        public var errorDescription: String? { description }
    }

    public static func run(device: MicChoice, formats: () throws -> (hardware: Format, output: Format),
                           align: () throws -> Void, rebuild: () throws -> Void) throws -> Outcome {
        var aligned = false, rebuilt = false
        while true {
            let (hardware, output) = try formats()
            if hardware.isValid, hardware == output { return .ready(aligned: aligned, rebuilt: rebuilt) }
            if hardware.isValid, device == .builtIn, !aligned {
                try align()
                aligned = true
            } else if !rebuilt {
                try rebuild()
                rebuilt = true
                aligned = false
            } else {
                throw Mismatch(hardware: hardware, output: output)
            }
        }
    }
}
