import Foundation
import CoreAudio

/// Device-selection boundary shared by the fallback engine and hardware-free fixtures.
struct CaptureBuiltInSelector {
    /// Historical single-attempt behavior, retained for the H2 RED control.
    var legacySingleAttempt = false
    var defaultIsBuiltIn: () throws -> Bool = {
        guard let current = AudioDevices.defaultInputDevice() else { return false }
        return try current == AudioDevices.builtInInput()
    }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    /// One budget spans both initial selection and any TapFormatPlan rebuild.
    final class Budget {
        var attempts = 0
        var retries = 0
        var lastError: Error?
    }

    func run(budget: Budget = Budget(), select: () throws -> Void, note: (String) -> Void) throws {
        if legacySingleAttempt { return try select() }
        while budget.attempts < 10 {
            budget.attempts += 1
            do {
                if try defaultIsBuiltIn() {
                    note("builtin_select=skipped_default")
                    return
                }
                try select()
                return
            } catch {
                // Failed route lookups have the same transient HAL errors as CurrentDevice.
                budget.lastError = error
                guard Self.isHardwareError(error), budget.attempts < 10, budget.retries < 9 else { throw error }
                budget.retries += 1
                note("builtin_select_retry=\(budget.retries)")
                sleep(0.15)
            }
        }
        throw budget.lastError ?? NSError(domain: "CaptureBuiltInSelector", code: 1)
    }

    static func isHardwareError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSOSStatusErrorDomain, let status = OSStatus(exactly: error.code) else { return false }
        return [kAudioHardwareNotRunningError, kAudioHardwareUnspecifiedError,
                kAudioHardwareUnknownPropertyError, kAudioHardwareBadPropertySizeError,
                kAudioHardwareIllegalOperationError, kAudioHardwareBadObjectError,
                kAudioHardwareBadDeviceError, kAudioHardwareBadStreamError,
                kAudioHardwareUnsupportedOperationError, kAudioHardwareNotReadyError]
            .contains(status)
    }
}
