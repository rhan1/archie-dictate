import Foundation

public enum MicChoice: Equatable, Sendable { case `default`, builtIn }

public protocol CaptureEngine: AnyObject {
    var isRunning: Bool { get }
    func start(device: MicChoice) throws
    @discardableResult func stop() -> [Float]
    func rebuild()
}

/// The recorder policy shared by the controller and headless lifecycle tests.
public final class CaptureLifecycle {
    public enum Finish: Sendable { case ok, held, noSTT, error }
    public enum End: Sendable {
        case finished(Finish), silence, cancel, fail, prewarmExpired, maxDuration
    }
    public let engine: CaptureEngine
    public private(set) var warmup = CaptureWarmup()
    public private(set) var hasPendingPrewarmExpiry = false
    public var scheduleExpiry: (() -> Void)?
    public var cancelExpiry: (() -> Void)?
    public var onEffect: ((CaptureWarmup.Effect) -> Void)?
    public var note: ((String) -> Void)?
    public var dropHooks: (() -> Void)?

    public init(engine: CaptureEngine) { self.engine = engine }

    private func apply(_ effects: [CaptureWarmup.Effect]) {
        for effect in effects {
            switch effect {
            case .startEngine:
                do { try engine.start(device: .default) }
                catch { note?("engine start failed: \(error)") }
            case .stopEngine: engine.stop()
            case .showWarming, .showLive: onEffect?(effect)
            }
        }
    }

    public func firstTap() {
        apply(warmup.firstTap())
        cancelExpiry?()
        hasPendingPrewarmExpiry = true
        scheduleExpiry?()
    }

    @discardableResult public func beginRecording(at time: TimeInterval) -> Bool {
        cancelExpiry?()
        hasPendingPrewarmExpiry = false
        apply(warmup.recordingStarted(at: time))
        return engine.isRunning
    }

    public func bufferArrived(at time: TimeInterval) { apply(warmup.bufferArrived(at: time)) }

    @discardableResult public func end(_ path: End) -> [Float] {
        switch path {
        case .prewarmExpired:
            hasPendingPrewarmExpiry = false
            apply(warmup.prewarmExpired())
            return []
        case .fail:
            warmup.stopped()
            return []
        default:
            let samples = engine.stop()
            warmup.stopped()
            return samples
        }
    }
}
