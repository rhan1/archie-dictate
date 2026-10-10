import Foundation

public enum MicChoice: Equatable, Sendable { case `default`, builtIn }

public protocol CaptureEngine: AnyObject {
    var isRunning: Bool { get }
    var isAllocated: Bool { get }
    func release()
    func start(device: MicChoice) throws
    @discardableResult func stop() -> [Float]
    func rebuild() throws
}

/// Main-event-queue policy; engine operations use the recorder's serial executor.
public final class CaptureLifecycle {
    public enum Finish: Sendable { case ok, held, noSTT, error }
    public enum End: Sendable {
        case finished(Finish), silence, cancel, fail, prewarmExpired, maxDuration
    }
    public static let firstBufferTimeout: TimeInterval = 3
    public let engine: CaptureEngine
    public private(set) var warmup = CaptureWarmup()
    public private(set) var hasPendingPrewarmExpiry = false
    public private(set) var usedBuiltIn = false
    public private(set) var epoch = CaptureEpoch()
    public var onEpochChanged: ((CaptureEpoch) -> Void)?
    public var scheduleExpiry: (() -> Void)?
    public var cancelExpiry: (() -> Void)?
    public var onEffect: ((CaptureWarmup.Effect) -> Void)?
    public var onFailure: (() -> Void)?
    public var onMaxDuration: (() -> Void)?
    public var note: ((String) -> Void)?
    public var dropHooks: (() -> Void)?
    private let scheduler: CaptureScheduler
    public let idleReleaseSeconds: TimeInterval
    private var idleGuard: CaptureCancellation?
    private var expiry: CaptureCancellation?
    private var firstBufferDeadline: CaptureCancellation?
    private var cap: CaptureCancellation?
    private var retryWait: CaptureCancellation?
    private var recordingRequested = false
    private var failureReported = false
    private var prewarmStarting = false

    public init(engine: CaptureEngine, scheduler: CaptureScheduler = CaptureDispatchScheduler(),
                idleReleaseSeconds: TimeInterval = 2.0) {
        precondition(idleReleaseSeconds > 0)
        self.engine = engine
        self.scheduler = scheduler
        self.idleReleaseSeconds = idleReleaseSeconds
        armIdleGuard()
    }

    private var isIdle: Bool {
        warmup.phase == .off && !recordingRequested && !hasPendingPrewarmExpiry && !prewarmStarting
    }
    private func cancelIdleGuard() { idleGuard?.cancel(); idleGuard = nil }
    private func armIdleGuard() {
        cancelIdleGuard()
        guard isIdle else { return }
        let token = epoch
        idleGuard = scheduler.schedule(after: idleReleaseSeconds) { [weak self] in
            guard let self, self.epoch === token, self.isIdle else { return }
            self.idleGuard = nil
            if self.engine.isAllocated {
                self.releaseEngine()
                self.note?("engine_idle_release")
            }
            // Keep watching for an allocation left by a late recovery operation.
            self.armIdleGuard()
        }
    }
    private func releaseEngine() {
        do { try captureObjC { engine.release() } }
        catch { logError(error) }
    }

    private func armExpiry() {
        cancelPrewarm()
        hasPendingPrewarmExpiry = true
        let token = epoch
        expiry = scheduler.schedule(after: CaptureWarmup.prewarmTimeout) { [weak self] in
            guard let self, self.epoch === token, !self.recordingRequested else { return }
            self.end(.prewarmExpired)
        }
        scheduleExpiry?() // compatibility with existing external expiry wiring
    }
    private func cancelPrewarm() {
        expiry?.cancel(); expiry = nil
        cancelExpiry?()
        hasPendingPrewarmExpiry = false
    }

    public func firstTap() {
        guard warmup.phase == .off, !recordingRequested, !prewarmStarting else { return }
        cancelIdleGuard()
        let token = CaptureEpoch()
        epoch = token
        prewarmStarting = true
        defer { if epoch === token { prewarmStarting = false; armExpiry() } }
        onEpochChanged?(token)
        guard epoch === token else { return }
        _ = warmup.firstTap()
        do {
            try captureObjC { try engine.start(device: .default) }
            guard epoch === token, !recordingRequested else { cleanLateStart(); return }
        } catch {
            guard epoch === token else { cleanLateStart(); return }
            logError(error)
            teardown()
        }
    }

    @MainActor public func firstTapAsync(start: (MicChoice) async throws -> Void,
                              isCancelled: () -> Bool) async {
        guard warmup.phase == .off, !recordingRequested, !prewarmStarting, !isCancelled() else { return }
        cancelIdleGuard()
        let token = CaptureEpoch()
        epoch = token
        prewarmStarting = true
        onEpochChanged?(token)
        guard epoch === token, !isCancelled() else { prewarmStarting = false; return }
        armExpiry() // bound even an in-flight prewarm
        _ = warmup.firstTap()
        defer { if epoch === token { prewarmStarting = false } }
        do {
            try await start(.default)
            guard epoch === token, !isCancelled() else { cleanLateStart(); return }
        } catch {
            guard epoch === token, !isCancelled() else { cleanLateStart(); return }
            logError(error)
            teardown()
            armExpiry() // existing failed-prewarm contract; next double tap still retries
        }
    }

    private func prepareRecording(at time: TimeInterval) -> CaptureEpoch {
        cancelIdleGuard()
        let token = CaptureEpoch()
        epoch = token
        prewarmStarting = false
        recordingRequested = true
        failureReported = false
        cancelPrewarm()
        firstBufferDeadline?.cancel(); firstBufferDeadline = nil
        cap?.cancel()
        cap = scheduler.schedule(after: DictationLimits.maxDuration) { [weak self] in
            guard let self, self.epoch === token, self.recordingRequested else { return }
            if let onMaxDuration = self.onMaxDuration { onMaxDuration() }
            else { self.end(.maxDuration) }
        }
        usedBuiltIn = false
        onEpochChanged?(token)
        guard epoch === token, recordingRequested else { return token }
        let effects = warmup.recordingStarted(at: time, engineRunning: engine.isRunning)
        for effect in effects where effect == .showLive || effect == .showWarming { onEffect?(effect) }
        return token
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
    private func terminalFailure() {
        end(.fail)
        guard !failureReported else { return }
        failureReported = true
        onFailure?()
    }
    private func cleanLateStart() {
        // A replaced operation may already own the running engine. The recorder's
        // epoch rejects stale hardware work; only clean idle here.
        if !recordingRequested, warmup.phase == .off {
            _ = stopEngine()
            releaseEngine()
            armIdleGuard()
        }
    }
    private func stopEngine() -> [Float] {
        do { return try captureObjC { engine.stop() } }
        catch {
            logError(error)
            // A failed stop/removeTap must abandon the poisoned engine.
            do { try captureObjC { try engine.rebuild() } }
            catch { logError(error) }
            return []
        }
    }
    private func resetAttempt() {
        _ = stopEngine()
        warmup.stopped()
        cancelPrewarm()
    }
    private func watchFirstBuffer(token: CaptureEpoch, retry: @escaping () -> Void) {
        firstBufferDeadline?.cancel()
        guard warmup.phase == .warming else { firstBufferDeadline = nil; return }
        firstBufferDeadline = scheduler.schedule(after: Self.firstBufferTimeout) { [weak self] in
            guard let self, self.epoch === token, self.recordingRequested,
                  self.warmup.phase == .warming else { return }
            self.firstBufferDeadline = nil
            retry()
        }
    }
    private var timeoutError: NSError {
        NSError(domain: "CaptureLifecycle", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No first buffer within 3 seconds"])
    }

    @discardableResult public func beginRecording(at time: TimeInterval) -> Bool {
        let token = prepareRecording(at: time)
        guard epoch === token, recordingRequested else { return false }
        return runSync(at: time, chain: MicStartChain(), token: token, alreadyRunning: engine.isRunning)
    }
    private func runSync(at time: TimeInterval, chain initial: MicStartChain, token: CaptureEpoch,
                         alreadyRunning: Bool = false) -> Bool {
        var chain = initial
        while chain.isAttempt {
            guard epoch === token, recordingRequested else { cleanLateStart(); return false }
            do {
                if chain.needsRebuild {
                    resetAttempt()
                    try captureObjC { try engine.rebuild() }
                }
                let device = chain.device
                if !alreadyRunning { try captureObjC { try engine.start(device: device) } }
                guard epoch === token, recordingRequested else { cleanLateStart(); return false }
                guard engine.isRunning else { throw NSError(domain: "CaptureLifecycle", code: 1) }
                let retryChain = chain
                recordingReady(at: time, device: device, fields: chain.succeeded())
                guard epoch === token, recordingRequested else { cleanLateStart(); return false }
                watchFirstBuffer(token: token) { [weak self] in
                    guard let self else { return }
                    var next = retryChain
                    self.failedAttempt(self.timeoutError, chain: &next)
                    self.resetAttempt()
                    if !next.isAttempt { self.terminalFailure(); return }
                    self.retryWait = self.scheduler.schedule(after: next.delay) { [weak self] in
                        guard let self, self.epoch === token, self.recordingRequested else { return }
                        self.retryWait = nil
                        _ = self.runSync(at: time, chain: next, token: token)
                    }
                }
                return true
            } catch {
                guard epoch === token, recordingRequested else { cleanLateStart(); return false }
                failedAttempt(error, chain: &chain)
            }
        }
        terminalFailure()
        return false
    }

    @MainActor public func beginRecordingAsync(at time: TimeInterval,
        start: @escaping (MicChoice) async throws -> Void, rebuild: @escaping () async throws -> Void,
        wait: @escaping (TimeInterval) async -> Void, isCancelled: @escaping () -> Bool) async -> Bool {
        guard !isCancelled() else { return false }
        let token = prepareRecording(at: time)
        return await runAsync(at: time, chain: MicStartChain(), start: start, rebuild: rebuild,
                              wait: wait, isCancelled: isCancelled, token: token)
    }
    @MainActor private func runAsync(at time: TimeInterval, chain initial: MicStartChain,
        start: @escaping (MicChoice) async throws -> Void, rebuild: @escaping () async throws -> Void,
        wait: @escaping (TimeInterval) async -> Void, isCancelled: @escaping () -> Bool,
        token: CaptureEpoch) async -> Bool {
        var chain = initial
        while chain.isAttempt {
            guard epoch === token, !isCancelled() else { cleanLateStart(); return false }
            do {
                if chain.needsRebuild {
                    warmup.stopped()
                    cancelPrewarm()
                    try await rebuild()
                    guard epoch === token, !isCancelled() else { cleanLateStart(); return false }
                }
                if chain.delay > 0 { await wait(chain.delay) }
                guard epoch === token, !isCancelled() else { cleanLateStart(); return false }
                let device = chain.device
                if !engine.isRunning || chain.needsRebuild { try await start(device) }
                guard epoch === token, !isCancelled() else { cleanLateStart(); return false }
                guard engine.isRunning else { throw NSError(domain: "CaptureLifecycle", code: 1) }
                let retryChain = chain
                recordingReady(at: time, device: device, fields: chain.succeeded())
                guard epoch === token, !isCancelled() else { cleanLateStart(); return false }
                watchFirstBuffer(token: token) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.epoch === token, !isCancelled(),
                              self.warmup.phase == .warming else { return }
                        var next = retryChain
                        self.failedAttempt(self.timeoutError, chain: &next)
                        if !next.isAttempt { self.terminalFailure(); return }
                        _ = await self.runAsync(at: time, chain: next, start: start, rebuild: rebuild,
                                               wait: wait, isCancelled: isCancelled, token: token)
                    }
                }
                return true
            } catch {
                guard epoch === token, !isCancelled() else { cleanLateStart(); return false }
                failedAttempt(error, chain: &chain)
            }
        }
        terminalFailure()
        return false
    }

    public func bufferArrived(at time: TimeInterval, epoch token: CaptureEpoch? = nil,
                              source: CaptureBridge.Source = .headset) {
        guard source == .headset else { return }
        if let token, epoch !== token { return }
        guard warmup.phase != .off else { return }
        for effect in warmup.bufferArrived(at: time) { onEffect?(effect) }
        if warmup.phase == .live { firstBufferDeadline?.cancel(); firstBufferDeadline = nil }
    }

    @discardableResult public func teardown() -> [Float] {
        firstBufferDeadline?.cancel(); firstBufferDeadline = nil
        retryWait?.cancel(); retryWait = nil
        cap?.cancel(); cap = nil
        recordingRequested = false
        prewarmStarting = false
        let samples = stopEngine()
        releaseEngine()
        warmup.stopped()
        cancelPrewarm()
        armIdleGuard()
        dropHooks?()
        return samples
    }
    @discardableResult public func end(_ path: End) -> [Float] {
        if case .prewarmExpired = path {
            guard hasPendingPrewarmExpiry, !recordingRequested else { return [] }
        }
        epoch = CaptureEpoch()
        onEpochChanged?(epoch)
        return teardown()
    }

    public func engineFailed(epoch token: CaptureEpoch) {
        guard epoch === token, recordingRequested else { return }
        terminalFailure()
    }
}
