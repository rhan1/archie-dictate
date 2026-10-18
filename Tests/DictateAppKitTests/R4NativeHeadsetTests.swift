import AVFoundation
import DictateCore
import DictateObjC
import Foundation
import Testing
@testable import DictateAppKit

/// R4 (v1.17): a native (Objective-C) exception at any headset conversion stage, on either headset
/// backend, at startup or on a format change. Each forced fault runs in a bounded CHILD process (the
/// test binary re-run on `child()` alone) so an abort is observed, not suffered. The child drives the
/// PCM consumers with offline PCM only: no engine start, microphone, real HAL driver, window or provider.
@Suite(.serialized)
struct R4NativeHeadsetTests {
    static let engineStages = ["target_format", "converter", "output_buffer", "convert"]
    static let auhalStages = ["target_format", "input_format", "converter", "input_buffer", "output_buffer", "convert"]
    static let forcedName = "DictateForcedHeadset"

    // MARK: child (no-op unless the parent set DICTATE_R4_BACKEND)

    @Test func child() throws {
        let env = ProcessInfo.processInfo.environment
        guard let backend = env["DICTATE_R4_BACKEND"], let requested = env["DICTATE_R4_STAGE"],
              let phase = env["DICTATE_R4_PHASE"] else { return }
        if backend == "rig" {
            // R4b: the rig speaker's engine/player constructors, forced to raise (nothing is constructed).
            let made = RigSpeaker.makePlayback { dictate_force_headset_exception(); fatalError("unreachable") }
            #expect(made == nil)
            FileHandle.standardOutput.write(Data("R4_CHILD stage=constructor backend=rig forced=1 result=\(made == nil ? "engine_error" : "constructed") alive=1\n".utf8))
            return
        }
        let forced = requested != "none"
        var fired = false
        var caught: [String] = []
        var caughtStages: [String] = []
        func install(_ seam: HeadsetNativeBoundary) {
            seam.before = { stage in
                guard forced, !fired, stage == requested else { return }
                fired = true
                dictate_force_headset_exception()
            }
            seam.onFailure = { stage, error in
                caughtStages.append(stage)
                caught.append((error.userInfo["name"] ?? error.userInfo["exceptionName"]) as? String ?? "unnamed")
            }
        }
        var secondBuffers = 0
        var second: [Float] = []
        var alive = true
        switch backend {
        case "engine":
            // The engine arm's own `consume` on one recorder: same lock, converter and boundary.
            let recorder = AudioRecorder(builtin: { CaptureLeaseRecorderTests.FakeBuiltin("offline", .init()) })
            var delivered: [[Float]] = []
            recorder.headsetNative.converted = { delivered.append($0) }
            let startRate = 44_100.0, changedRate = 16_000.0
            if phase == "change" {
                recorder.offlineHeadsetBuffer(try Self.sine(rate: startRate))
                #expect(delivered.count == 1, "pre-change buffer converts")
            }
            install(recorder.headsetNative)
            let buffer = try Self.sine(rate: phase == "change" ? changedRate : startRate)
            delivered.removeAll()
            recorder.offlineHeadsetBuffer(buffer)
            if forced { #expect(delivered.isEmpty, "the faulted buffer is dropped, not half-converted") }
            delivered.removeAll()
            recorder.offlineHeadsetBuffer(buffer)          // the NEXT buffer, same recorder instance
            secondBuffers = delivered.count
            second = delivered.flatMap { $0 }
        case "auhal":
            let driver = FakeHALDriver()
            let recorder = HeadsetCaptureUnit(driver: driver, workerInterval: 3600) // drained by hand
            recorder.note = { _ in }
            let epoch = CaptureEpoch()
            var delivered: [[Float]] = []
            recorder.onFrames = { frames, _, _ in delivered.append(frames) }
            if phase == "change" { try recorder.start(deviceUID: "offline", epoch: epoch) }
            install(recorder.headsetNative)
            if phase == "startup" { try recorder.start(deviceUID: "offline", epoch: epoch) }
            else { driver.currentFormatResult = HALStreamFormat(sampleRate: 16_000, channels: 1) }
            let samples = FakeHALDriver.sine(count: 4800, sampleRate: 44_100).map { $0 * 0.2 }
            driver.push(samples: samples)
            recorder.offlineDrain()
            delivered.removeAll()
            driver.push(samples: samples)                  // the NEXT buffer, same unit instance
            recorder.offlineDrain()
            secondBuffers = delivered.count
            second = delivered.flatMap { $0 }
            alive = recorder.isRunning
            #expect(recorder.counters.callbacks == 2, "every slot, failed or not, is released and counted")
            recorder.stop()
        default:
            Issue.record("unknown backend")
        }
        let nonzero = second.contains { abs($0) > 0.001 }
        #expect(fired == forced)
        #expect(caught == (forced ? [Self.forcedName] : []))
        #expect(caughtStages == (forced ? [requested] : []))
        #expect(alive)
        #expect(secondBuffers == 1)
        #expect(nonzero)
        let line = "R4_CHILD stage=\(requested)@\(phase) backend=\(backend) forced=\(forced ? 1 : 0) "
            + "caught=\(caught.first ?? "none") alive=\(alive ? 1 : 0) second_buffers=\(secondBuffers) "
            + "second_frames=\(second.count) second_nonzero=\(nonzero ? 1 : 0)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func sine(rate: Double, frames: Int = 4800) throws -> AVAudioPCMBuffer {
        let format = try NativePCM.format(.pcmFormatFloat32, rate: rate, channels: 1, interleaved: false)
        let buffer = try NativePCM.buffer(format, capacity: frames)
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = Float(sin(2 * Double.pi * 440 * Double(i) / rate) * 0.2) }
        return buffer
    }

    // MARK: parent

    struct ChildResult { let line: String?; let signal: Int32?; let status: Int32; let output: String }

    static func runChild(backend: String, stage: String, phase: String) throws -> ChildResult {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--test-bundle-path"), index + 1 < args.count else {
            throw NSError(domain: "R4", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "no --test-bundle-path in runner arguments (\(args.count) args)"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = ["--test-bundle-path", args[index + 1], "--testing-library", "swift-testing",
                             "--filter", "R4NativeHeadsetTests/child"]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SWT_") }
        environment["DICTATE_R4_BACKEND"] = backend
        environment["DICTATE_R4_STAGE"] = stage
        environment["DICTATE_R4_PHASE"] = phase
        process.environment = environment
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-r4-child-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try handle.close()
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let line = output.split(separator: "\n").first { $0.hasPrefix("R4_CHILD ") }.map(String.init)
        let signal = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        return ChildResult(line: line, signal: signal, status: process.terminationStatus, output: output)
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: "SIGABRT"
        case SIGKILL: "SIGKILL"
        case SIGSEGV: "SIGSEGV"
        case SIGTRAP: "SIGTRAP"
        case SIGBUS: "SIGBUS"
        default: "SIG\(signal)"
        }
    }

    /// Every stage × backend × phase forced once (plus an unforced row per backend × phase); the same
    /// recorder must survive and convert its next buffer. Prints one NATIVE line per row.
    @Test func nativeFaultMatrix() throws {
        guard ProcessInfo.processInfo.environment["DICTATE_R4_BACKEND"] == nil else { return }
        var allGreen = true
        for (backend, stages) in [("engine", Self.engineStages), ("auhal", Self.auhalStages)] {
            for phase in ["startup", "change"] {
                for stage in stages + ["none"] {
                    let result = try Self.runChild(backend: backend, stage: stage, phase: phase)
                    if let signal = result.signal {
                        allGreen = false
                        print("NATIVE RED stage=\(stage)@\(phase) backend=\(backend) forced=\(stage == "none" ? 0 : 1) "
                              + "child_signal=\(Self.signalName(signal)) second_buffers=0")
                    } else if let line = result.line, result.status == 0 {
                        let label = stage == "none" ? "NATIVE NEGATIVE" : "NATIVE GREEN"
                        print(line.replacingOccurrences(of: "R4_CHILD", with: label))
                    } else {
                        allGreen = false
                        print("NATIVE FAIL stage=\(stage)@\(phase) backend=\(backend) exit=\(result.status) "
                              + "line=\(result.line ?? "none")")
                        Issue.record("child failed \(backend) \(stage)@\(phase):\n\(result.output.suffix(3000))")
                    }
                    #expect(result.signal == nil, "child died: \(backend) \(stage)@\(phase)")
                    #expect(result.status == 0)
                    if stage == "none" {
                        #expect(result.line?.contains("forced=0 caught=none alive=1 second_buffers=1") == true)
                    } else {
                        #expect(result.line?.contains("forced=1 caught=\(Self.forcedName) alive=1 second_buffers=1") == true)
                    }
                    #expect(result.line?.contains("second_nonzero=1") == true)
                }
            }
        }
        if allGreen { print("CONTROL same_recorder_conversion_recovery PASS rows=24 backends=engine,auhal phases=startup,change") }
    }

    /// R4b: `RigSpeaker.swift`'s AVAudioEngine/AVAudioPlayerNode constructors raise → `engine_error`, alive.
    @Test func rigConstructorFault() throws {
        guard ProcessInfo.processInfo.environment["DICTATE_R4_BACKEND"] == nil else { return }
        let result = try Self.runChild(backend: "rig", stage: "constructor", phase: "startup")
        if let signal = result.signal {
            print("RIG RED stage=constructor backend=rig forced=1 child_signal=\(Self.signalName(signal))")
        } else if let line = result.line, result.status == 0, line.contains("result=engine_error alive=1") {
            print(line.replacingOccurrences(of: "R4_CHILD", with: "RIG GREEN"))
            print("CONTROL rig_constructor_guard PASS result=engine_error")
        } else {
            Issue.record("rig child failed:\n\(result.output.suffix(2000))")
        }
        #expect(result.signal == nil)
        #expect(result.line?.contains("result=engine_error alive=1") == true)
    }

    // MARK: guard controls (the existing guards themselves, in-process)

    /// Positive control: Dictate's guards really catch a raised NSException — one raised by a test
    /// seam inside the guarded closure (captureObjC), one raised by a real AVAudioConverter subclass
    /// inside the native conversion call (NativePCM.convert).
    @Test func guardPositiveControl() throws {
        var names: [String] = []
        do {
            try captureObjC { dictate_force_headset_exception() }
            Issue.record("captureObjC let the forced exception through")
        } catch {
            names.append(((error as NSError).userInfo["name"] as? String) ?? "unnamed")
        }
        let from = try NativePCM.format(.pcmFormatFloat32, rate: 44_100, channels: 1, interleaved: false)
        let to = try NativePCM.format(.pcmFormatFloat32, rate: 24_000, channels: 1, interleaved: false)
        let out = try NativePCM.buffer(to, capacity: 4096)
        let input = try Self.sine(rate: 44_100)
        do {
            _ = try NativePCM.convert(dictate_throwing_converter(from, to), to: out) { _, status in
                status.pointee = .haveData
                return input
            }
            Issue.record("NativePCM.convert let the forced exception through")
        } catch {
            names.append(((error as NSError).userInfo["exceptionName"] as? String) ?? "unnamed")
        }
        #expect(names == [Self.forcedName, "DictateForcedConvert"])
        if names == [Self.forcedName, "DictateForcedConvert"] {
            print("CONTROL native_guard_positive PASS caught=\(names.joined(separator: ","))")
        }
    }

    /// Negative control: no forced fault → the guards catch nothing and conversion yields real frames.
    @Test func guardNegativeControl() throws {
        let value = try captureObjC { 42 }
        let from = try NativePCM.format(.pcmFormatFloat32, rate: 44_100, channels: 1, interleaved: false)
        let to = try NativePCM.format(.pcmFormatFloat32, rate: 24_000, channels: 1, interleaved: false)
        let converter = try NativePCM.converter(from: from, to: to)
        let out = try NativePCM.buffer(to, capacity: 4096)
        let input = try Self.sine(rate: 44_100)
        var fed = false
        _ = try NativePCM.convert(converter, to: out) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        let frames = Int(out.frameLength)
        let nonzero = (0..<frames).contains { abs(out.floatChannelData![0][$0]) > 0.001 }
        #expect(value == 42)
        #expect(frames > 0)
        #expect(nonzero)
        if value == 42, frames > 0, nonzero { print("CONTROL native_guard_negative PASS caught=none frames=\(frames)") }
    }
}
