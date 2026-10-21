import Foundation
import CoreAudio
import DictateCore

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
        var formatRetries = 0
        var requiresExplicitSelection = false
        var lastError: Error?
    }

    func run(budget: Budget = Budget(), hardwareFormatValid: () throws -> Bool = { false },
             select: () throws -> Void, note: (String) -> Void) throws {
        if legacySingleAttempt { return try select() }
        while budget.attempts < 10 {
            budget.attempts += 1
            do {
                // A fresh engine may still expose 0 Hz / 0 ch after VPIO teardown,
                // even when the system default already names the built-in device.
                if !budget.requiresExplicitSelection, try defaultIsBuiltIn(), try hardwareFormatValid() {
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

    /// Only fallback starts treat a zero hardware format as transient. Selection,
    /// format waits and TapFormatPlan rebuilds all consume the same bounded budget.
    func startFallback(budget: Budget = Budget(), hardwareFormatValid: () throws -> Bool,
                       select: () throws -> Void, rebuild: () throws -> Void,
                       start: () throws -> Void, note: (String) -> Void) throws {
        while true {
            try run(budget: budget, hardwareFormatValid: hardwareFormatValid, select: select, note: note)
            do { try start(); return }
            catch {
                guard Self.isFormatNotReady(error) else { throw error }
                budget.lastError = error
                guard budget.attempts < 10, budget.retries < 9 else { throw error }
                budget.retries += 1
                budget.formatRetries += 1
                budget.requiresExplicitSelection = true
                note("builtin_format_retry=\(budget.formatRetries)")
                sleep(0.15)
                try rebuild()
            }
        }
    }

    static func isFormatNotReady(_ error: Error) -> Bool {
        guard let mismatch = error as? TapFormatPlan.Mismatch else { return false }
        return !mismatch.hardware.isValid
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
