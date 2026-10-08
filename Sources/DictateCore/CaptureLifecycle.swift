import Foundation

public enum MicChoice: Equatable, Sendable { case `default`, builtIn }

public protocol CaptureEngine: AnyObject {
    var isRunning: Bool { get }
    func start(device: MicChoice) throws
    @discardableResult func stop() -> [Float]
    func rebuild()
}

/// Recorder policy shared by the controller and headless lifecycle tests.
/// Async entry points run engine operations through the supplied serial executor.
public final class CaptureLifecycle {
    public enum Finish: Sendable { case ok, held, noSTT, error }
    public enum End: Sendable {
        case finished(Finish), silence, cancel, fail, prewarmExpired, maxDuration
    }
    public let engine: CaptureEngine
    public private(set) var warmup = CaptureWarmup()
    public private(set) var hasPendingPrewarmExpiry = false
    public private(set) var usedBuiltIn = false
    public var scheduleExpiry: (() -> Void)?
    public var cancelExpiry: (() -> Void)?
    public var onEffect: ((CaptureWarmup.Effect) -> Void)?
    public var note: ((String) -> Void)?
    public var dropHooks: (() -> Void)?
    private var operation = 0

    public init(engine: CaptureEngine) { self.engine = engine }

    private func armExpiry() {
        cancelExpiry?()
        hasPendingPrewarmExpiry = true
        scheduleExpiry?()
    }
    private func cancelPrewarm() {
        cancelExpiry?()
        hasPendingPrewarmExpiry = false
    }

    public func firstTap() {
        guard warmup.phase == .off else { return }
        defer { armExpiry() }
        do {
            try captureObjC { try engine.start(device: .default) }
            _ = warmup.firstTap() // commit .prewarming only after successful start
        } catch {
            logError(error)
            teardown()
        }
    }

    @MainActor public func firstTapAsync(start: (MicChoice) async throws -> Void,
                              isCancelled: () -> Bool) async {
        guard warmup.phase == .off, !isCancelled() else { return }
        let token = operation
        defer { if token == operation && !isCancelled() { armExpiry() } }
        do {
            try await start(.default)
            guard token == operation && !isCancelled() else { return }
            _ = warmup.firstTap()
        } catch {
            guard token == operation && !isCancelled() else { return }
            logError(error)
            teardown()
        }
    }

    private func prepareRecording(at time: TimeInterval) {
        operation += 1
        cancelPrewarm()
        usedBuiltIn = false
        // Real engine state is authoritative, even if the phase says prewarming/live.
        let effects = warmup.recordingStarted(at: time, engineRunning: engine.isRunning)
        for effect in effects where effect == .showLive || effect == .showWarming { onEffect?(effect) }
    }
    private func recordingReady(at time: TimeInterval, device: MicChoice, fields: [String]) {
        usedBuiltIn = device == .builtIn
        fields.forEach { note?($0) }
        for effect in warmup.recordingStarted(at: time, engineRunning: true) { onEffect?(effect) }
    }
    private func logError(_ error: Error) {
        let e = error as NSError
        note?("mic_error=\(e.domain):\(e.code) \(e.localizedDescription)")
    }
    private func failedAttempt(_ error: Error, chain: inout MicStartChain) {
        note?("warm_phase=\(warmup.phase) engine_running=\(engine.isRunning)")
        chain.failed(error).forEach { note?($0) }
    }

    /// Synchronous harness; production uses the asynchronous entry point below.
    @discardableResult public func beginRecording(at time: TimeInterval) -> Bool {
        prepareRecording(at: time)
        if engine.isRunning { return true }
        var chain = MicStartChain()
        while chain.isAttempt {
            if chain.needsRebuild { teardown(); engine.rebuild() }
            do {
                let device = chain.device
                try captureObjC { try engine.start(device: device) }
                guard engine.isRunning else { throw NSError(domain: "CaptureLifecycle", code: 1) }
                recordingReady(at: time, device: device, fields: chain.succeeded())
                return true
            } catch { failedAttempt(error, chain: &chain) }
        }
        teardown()
        return false
    }

    @MainActor public func beginRecordingAsync(at time: TimeInterval,
        start: (MicChoice) async throws -> Void, rebuild: () async -> Void,
        wait: (TimeInterval) async -> Void, isCancelled: () -> Bool) async -> Bool {
        guard !isCancelled() else { return false }
        prepareRecording(at: time)
        let token = operation
        if engine.isRunning { return !isCancelled() }
        var chain = MicStartChain()
        while chain.isAttempt {
            guard token == operation && !isCancelled() else { return false }
            if chain.needsRebuild {
                // Recorder rebuild performs the engine teardown on its serial queue.
                cancelPrewarm()
                warmup.stopped()
                dropHooks?()
                await rebuild()
                guard token == operation && !isCancelled() else { return false }
            }
            if chain.delay > 0 { await wait(chain.delay) }
            guard token == operation && !isCancelled() else { return false }
            do {
                let device = chain.device
                try await start(device)
                guard token == operation && !isCancelled() else { return false }
                guard engine.isRunning else { throw NSError(domain: "CaptureLifecycle", code: 1) }
                recordingReady(at: time, device: device, fields: chain.succeeded())
                return true
            } catch {
                guard token == operation && !isCancelled() else { return false }
                failedAttempt(error, chain: &chain)
            }
        }
        teardown()
        return false
    }

    public func bufferArrived(at time: TimeInterval) {
        for effect in warmup.bufferArrived(at: time) { onEffect?(effect) }
    }

    /// Every terminal path, including partial starts, converges here. Engine.stop
    /// flushes audio before hooks are detached so successful transcription keeps it.
    @discardableResult public func teardown() -> [Float] {
        let samples = engine.stop()
        warmup.stopped()
        cancelPrewarm()
        dropHooks?()
        return samples
    }
    @discardableResult public func end(_ path: End) -> [Float] {
        operation += 1 // invalidates in-flight prewarm/recovery work
        return teardown()
    }
}
