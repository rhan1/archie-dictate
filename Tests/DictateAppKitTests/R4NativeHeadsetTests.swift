import AVFoundation
import DictateCore
import DictateObjC
import Foundation
import Testing
@testable import DictateAppKit

/// Each abort is isolated in a bounded child. The child runs PCM consumers only:
/// no engine, microphone, real HAL driver, run loop, window, or provider.
@Suite(.serialized)
struct R4NativeHeadsetTests {
    @Test func child() throws {
        let env = ProcessInfo.processInfo.environment
        guard let backend = env["DICTATE_R4_BACKEND"], let requested = env["DICTATE_R4_STAGE"] else { return }
        let phase = env["DICTATE_R4_PHASE"] ?? "startup"
        let forced = requested != "none"
        var fired = false
        var caught: [String] = []
        var caughtStages: [String] = []
        func install(_ seam: HeadsetNativeBoundary) {
            seam.before = { stage in
                if forced, !fired, stage == requested {
                    fired = true
                    dictate_force_headset_exception()
                }
            }
            seam.onFailure = { stage, error in
                caughtStages.append(stage)
                caught.append((error.userInfo["name"] ?? error.userInfo["exceptionName"]) as? String ?? "missing")
            }
        }
        func pcm(_ rate: Double) throws -> AVAudioPCMBuffer {
            let f = try NativePCM.format(.pcmFormatFloat32, rate: rate, channels: 1, interleaved: false)
            let b = try NativePCM.buffer(f, capacity: 4800)
            b.frameLength = 4800
            for i in 0..<4800 { b.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.2) }
            return b
        }
        var second: [Float] = []
        var alive = true
        if backend == "engine" {
            let recorder = AudioRecorder(builtin: { CaptureLeaseRecorderTests.FakeBuiltin("offline", .init()) })
            if phase == "change" { #expect(!(recorder.offlineHeadsetPCM(try pcm(44100)) ?? []).isEmpty) }
            install(recorder.headsetNative)
            let buffer = try pcm(phase == "change" ? 16000 : 44100)
            let first = recorder.offlineHeadsetPCM(buffer)
            if forced { #expect(first == nil) }
            second = recorder.offlineHeadsetPCM(buffer) ?? []
        } else {
            let driver = FakeHALDriver()
            let recorder = HeadsetCaptureUnit(driver: driver, workerInterval: 3600)
            recorder.note = { _ in }
            let epoch = CaptureEpoch()
            var delivered: [[Float]] = []
            recorder.onFrames = { frames, _, _ in delivered.append(frames) }
            if phase == "change" { try recorder.start(deviceUID: "offline", epoch: epoch) }
            install(recorder.headsetNative)
            if phase == "startup" { try recorder.start(deviceUID: "offline", epoch: epoch) }
            else { driver.currentFormatResult = HALStreamFormat(sampleRate: 16000, channels: 1) }
            driver.push(samples: Array(repeating: 0.2, count: 4800))
            recorder.offlineDrainPCM()
            delivered.removeAll()
            driver.push(samples: Array(repeating: 0.2, count: 4800))
            recorder.offlineDrainPCM()
            second = delivered.flatMap { $0 }
            alive = recorder.isRunning
            #expect(recorder.counters.callbacks == 2) // failed slots must still be released
            recorder.stop()
        }
        #expect(fired == forced)
        #expect(caught == (forced ? ["DictateForcedHeadset"] : []))
        #expect(caughtStages == (forced ? [requested] : []))
        #expect(alive)
        #expect(!second.isEmpty)
        #expect(second.contains { abs($0) > 0.001 })
        print("R4_CHILD stage=\(requested)_\(phase) backend=\(backend) forced=\(forced ? 1 : 0) caught=\(caught.first ?? "none") alive=\(alive ? 1 : 0) second_buffers=\(second.isEmpty ? 0 : 1) second_frames=\(second.count) second_nonzero=\(second.contains { abs($0) > 0.001 } ? 1 : 0)")
    }

    @Test func nativeFaultMatrixAndControls() throws {
        guard ProcessInfo.processInfo.environment["DICTATE_R4_BACKEND"] == nil else { return }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        for backend in ["engine", "auhal"] {
            let stages = backend == "engine" ? ["target_format", "converter", "output_buffer", "convert"] :
                ["target_format", "input_format", "converter", "input_buffer", "output_buffer", "convert"]
            for phase in ["startup", "change"] {
                for stage in stages + ["none"] {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = ["--testing-library", "swift-testing", "--filter", "R4NativeHeadsetTests/child"]
                    var environment = ProcessInfo.processInfo.environment
                    environment["DICTATE_R4_BACKEND"] = backend
                    environment["DICTATE_R4_STAGE"] = stage
                    environment["DICTATE_R4_PHASE"] = phase
                    process.environment = environment
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    let deadline = Date().addingTimeInterval(15)
                    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                    if process.isRunning { process.terminate() }
                    let killDeadline = Date().addingTimeInterval(1)
                    while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGABRT {
                        print("NATIVE RED stage=\(stage)_\(phase) backend=\(backend) forced=1 child_signal=SIGABRT second_buffers=0")
                    } else if let line = output.split(separator: "\n").first(where: { $0.hasPrefix("R4_CHILD ") }) {
                        print(line.replacingOccurrences(of: "R4_CHILD", with: "NATIVE GREEN"))
                    } else { Issue.record("child classification failed backend=\(backend) stage=\(stage) status=\(process.terminationStatus) output=\(output.prefix(1000))") }
                    #expect(process.terminationReason == .exit)
                    #expect(process.terminationStatus == 0)
                    #expect(output.contains("R4_CHILD stage=\(stage)_\(phase)"))
                }
            }
        }
    }
}
