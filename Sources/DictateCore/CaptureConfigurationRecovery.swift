import Foundation

/// The AVAudioEngine notification boundary supplies identity/epoch checks and
/// hardware calls. This policy is also exercised without opening audio hardware.
public enum CaptureConfigurationRecovery {
    public enum Result: Equatable { case stale, retapped, rebuilt, failed }
    /// The recorder calls this under its state lock after hardware recovery.
    public static func activate(epoch: CaptureEpoch, current: CaptureEpoch,
                                _ activation: () -> Void) -> Bool {
        guard current === epoch else { return false }
        activation()
        return true
    }
    public static func run(isCurrent: () -> Bool, retap: () throws -> Void,
                           rebuildAndStart: () throws -> Void, teardown: () -> Void,
                           note: (Error) -> Void) -> Result {
        guard isCurrent() else { return .stale }
        do {
            try captureObjC(retap)
            guard isCurrent() else { teardown(); return .stale }
            return .retapped
        } catch { note(error) }
        guard isCurrent() else { teardown(); return .stale }
        do {
            try captureObjC(rebuildAndStart)
            guard isCurrent() else { teardown(); return .stale }
            return .rebuilt
        } catch { note(error); teardown(); return .failed }
    }

    /// Cleanup continues after each individual stop/remove/reset exception.
    @discardableResult public static func teardown(_ calls: [() throws -> Void],
                                                   note: (Error) -> Void) -> Bool {
        var succeeded = true
        for call in calls {
            do { try captureObjC(call) }
            catch { succeeded = false; note(error) }
        }
        return succeeded
    }
}
