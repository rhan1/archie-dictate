import AVFoundation
import CoreAudio
import DictateCore
@testable import DictateAppKit
import Foundation
import Testing

final class FakeHALDriver: HALInputDriver {
    enum Call: Equatable {
        case resolveDevice(String)
        case open(UInt32)
        case configure(Double, Int)
        case start
        case stop
        case listen(UInt32)
    }

    var calls: [Call] = []
    var resolveDeviceResult: UInt32 = 42
    var resolveDeviceError: Error?
    var openResult = HALStreamFormat(sampleRate: 44100, channels: 1)
    var openError: Error?
    var configureError: Error?
    var startError: Error?
    var stopErrors: [Error] = []
    var stopCallCount = 0

    var currentFormatResult: HALStreamFormat? = HALStreamFormat(sampleRate: 44100, channels: 1)
    var isAliveResult = true
    var renderSink: HALRenderSink?
    var listenerCallback: (() -> Void)?

    func resolveDevice(uid: String) throws -> UInt32 {
        calls.append(.resolveDevice(uid))
        if let resolveDeviceError { throw resolveDeviceError }
        return resolveDeviceResult
    }

    func open(device: UInt32) throws -> HALStreamFormat {
        calls.append(.open(device))
        if let openError { throw openError }
        return openResult
    }

    func configure(clientRate: Double, channels: Int, render: @escaping HALRenderSink) throws {
        calls.append(.configure(clientRate, channels))
        if let configureError { throw configureError }
        self.renderSink = render
    }

    func start() throws {
        calls.append(.start)
        if let startError { throw startError }
    }

    func stop() -> [Error] {
        calls.append(.stop)
        stopCallCount += 1
        return stopErrors
    }

    func currentFormat() -> HALStreamFormat? {
        return currentFormatResult
    }

    func isAlive(device: UInt32) -> Bool {
        return isAliveResult
    }

    func listen(device: UInt32, onChange: @escaping () -> Void) -> AnyObject {
        calls.append(.listen(device))
        listenerCallback = onChange
        return self
    }

    func unlisten(_ token: AnyObject) {
        listenerCallback = nil
    }

    func push(samples: [Float], hostTime: UInt64 = 0) {
        guard let renderSink else { return }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            renderSink(base, buffer.count, hostTime)
        }
    }

    func changeFormat(sampleRate: Double, channels: Int = 1) {
        currentFormatResult = HALStreamFormat(sampleRate: sampleRate, channels: channels)
        listenerCallback?()
    }

    func killDevice() {
        isAliveResult = false
        listenerCallback?()
    }

    func fireListener() {
        listenerCallback?()
    }

    static func sine(count: Int, sampleRate: Double, frequency: Double = 440) -> [Float] {
        (0..<count).map { i in
            Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
        }
    }
}

@Suite("HeadsetCaptureUnit")
struct HeadsetCaptureUnitTests {
    @Test func startBindsTheUIDInputOnly() throws {
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)
        var events: [(HeadsetCaptureEvent, CaptureEpoch)] = []
        unit.onEvent = { event, epoch in events.append((event, epoch)) }

        let epoch = CaptureEpoch()
        let targetUID = "58-18-62-21-1C-6A:input"
        try unit.start(deviceUID: targetUID, epoch: epoch)

        #expect(fake.calls.count >= 4)
        #expect(fake.calls[0] == .resolveDevice(targetUID))
        #expect(fake.calls[1] == .open(42))
        #expect(fake.calls[2] == .configure(44100, 1))
        #expect(fake.calls[3] == .start)

        #expect(events.contains { event, ep in
            event == .started(deviceUID: targetUID, sampleRate: 44100, channels: 1) && ep === epoch
        })
        #expect(unit.formatGeneration == 1)
        #expect(unit.isRunning)

        unit.stop()
    }

    @Test func framesAreConvertedTo24kWithHostTimes() throws {
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)
        var delivered: [Float] = []
        var deliveredHostTimes: [TimeInterval] = []
        let lock = NSLock()
        unit.onFrames = { chunk, hostTime, _ in
            lock.withLock {
                delivered.append(contentsOf: chunk)
                deliveredHostTimes.append(hostTime)
            }
        }

        let epoch = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: epoch)

        let sine = FakeHALDriver.sine(count: 4410, sampleRate: 44100)
        let fakeHostTime: UInt64 = 12_345_678
        fake.push(samples: sine, hostTime: fakeHostTime)

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            let count = lock.withLock { delivered.count }
            if count >= 2400 - 256 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let totalFrames = lock.withLock { delivered.count }
        let hostTimes = lock.withLock { deliveredHostTimes }
        #expect(abs(totalFrames - 2400) <= 256)   // one buffer keeps the resampler priming latency (~180 samples), as BuiltinCaptureUnit
        #expect(unit.counters.callbacks == 1)
        #expect(unit.counters.frames == totalFrames)
        #expect(!hostTimes.isEmpty)
        let expectedHostSecs = AVAudioTime.seconds(forHostTime: fakeHostTime)
        #expect(abs(hostTimes[0] - expectedHostSecs) < 0.001)

        unit.stop()
    }

    @Test func rateChangeIsAStateTransition() throws {
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)
        var events: [HeadsetCaptureEvent] = []
        var delivered: [Float] = []
        let lock = NSLock()
        unit.onEvent = { event, _ in lock.withLock { events.append(event) } }
        unit.onFrames = { chunk, _, _ in lock.withLock { delivered.append(contentsOf: chunk) } }

        let epoch = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: epoch)
        #expect(unit.formatGeneration == 1)

        fake.changeFormat(sampleRate: 16000, channels: 1)

        let deadline1 = Date().addingTimeInterval(10.0)
        while Date() < deadline1 {
            let changed = lock.withLock {
                events.contains(.formatChanged(generation: 2, sampleRate: 16000, channels: 1))
            }
            if changed { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        #expect(lock.withLock { events.contains(.formatChanged(generation: 2, sampleRate: 16000, channels: 1)) })
        #expect(unit.formatGeneration == 2)

        lock.withLock { delivered.removeAll() }
        let sine = FakeHALDriver.sine(count: 1600, sampleRate: 16000)
        fake.push(samples: sine, hostTime: 10_000_000)

        let deadline2 = Date().addingTimeInterval(10.0)
        while Date() < deadline2 {
            let count = lock.withLock { delivered.count }
            if count >= 2400 - 256 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let count = lock.withLock { delivered.count }
        #expect(abs(count - 2400) <= 64)

        unit.stop()
    }

    @Test func invalidRateDropsFramesUntilValid() throws {
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)
        var events: [HeadsetCaptureEvent] = []
        var delivered: [Float] = []
        let lock = NSLock()
        unit.onEvent = { event, _ in lock.withLock { events.append(event) } }
        unit.onFrames = { chunk, _, _ in lock.withLock { delivered.append(contentsOf: chunk) } }

        let epoch = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: epoch)

        fake.changeFormat(sampleRate: 0, channels: 1)
        fake.fireListener()

        let deadline1 = Date().addingTimeInterval(10.0)
        while Date() < deadline1 {
            let hasInvalid = lock.withLock { events.contains(.formatInvalid(generation: 1)) }
            if hasInvalid { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let invalidCount = lock.withLock { events.filter { $0 == .formatInvalid(generation: 1) }.count }
        #expect(invalidCount == 1)

        // Push frames while invalid
        fake.push(samples: [Float](repeating: 0.5, count: 441))
        Thread.sleep(forTimeInterval: 0.03)
        let deliveredWhileInvalid = lock.withLock { delivered.count }
        #expect(deliveredWhileInvalid == 0)

        // Switch to 16000 Hz
        fake.changeFormat(sampleRate: 16000, channels: 1)

        let deadline2 = Date().addingTimeInterval(10.0)
        while Date() < deadline2 {
            let hasChanged = lock.withLock { events.contains(.formatChanged(generation: 2, sampleRate: 16000, channels: 1)) }
            if hasChanged { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        #expect(lock.withLock { events.contains(.formatChanged(generation: 2, sampleRate: 16000, channels: 1)) })

        // Frames flow again
        let sine = FakeHALDriver.sine(count: 1600, sampleRate: 16000)
        fake.push(samples: sine)

        let deadline3 = Date().addingTimeInterval(10.0)
        while Date() < deadline3 {
            let count = lock.withLock { delivered.count }
            if count >= 2400 - 256 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let finalCount = lock.withLock { delivered.count }
        #expect(abs(finalCount - 2400) <= 64)

        unit.stop()
    }

    @Test func deviceLossIsReportedOnce() throws {
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)
        var events: [HeadsetCaptureEvent] = []
        let lock = NSLock()
        unit.onEvent = { event, _ in lock.withLock { events.append(event) } }

        let epoch = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: epoch)

        fake.isAliveResult = false
        fake.fireListener()
        fake.fireListener()

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            let lostCount = lock.withLock { events.filter { $0 == .deviceLost }.count }
            if lostCount >= 1 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let lostCount = lock.withLock { events.filter { $0 == .deviceLost }.count }
        #expect(lostCount == 1)
        #expect(unit.isRunning)

        unit.stop()
    }

    /// On an injected clock: the stall is measured in the unit's own time, so machine load cannot
    /// make it fire early or late (the loops below are hang detectors, not timing bounds).
    @Test func callbackCessationIsReported() throws {
        final class TestClock: @unchecked Sendable {
            private let lock = NSLock()
            private var t: TimeInterval = 100
            var now: TimeInterval { lock.withLock { t } }
            func advance(_ d: TimeInterval) { lock.withLock { t += d } }
        }
        let clock = TestClock()
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, clock: { clock.now }, workerInterval: 0.005)
        var events: [HeadsetCaptureEvent] = []
        let lock = NSLock()
        unit.onEvent = { event, _ in lock.withLock { events.append(event) } }
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10.0)
            while Date() < deadline, !condition() { Thread.sleep(forTimeInterval: 0.005) }
        }
        func stalls() -> Int { lock.withLock { events.filter { $0 == .callbacksStopped }.count } }

        let epoch = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: epoch)
        fake.push(samples: [0.1, 0.2, 0.3])
        waitFor { unit.counters.callbacks == 1 }                  // the worker saw the callback
        clock.advance(HeadsetCaptureUnit.callbackStall - 0.01)
        Thread.sleep(forTimeInterval: 0.05)                         // several worker ticks
        #expect(stalls() == 0)                                      // 490 ms of unit time: not yet
        clock.advance(0.02)
        waitFor { stalls() == 1 }
        #expect(stalls() == 1)

        fake.push(samples: [0.1, 0.2, 0.3])                         // callbacks resume: latch reset
        waitFor { unit.counters.callbacks == 2 }
        clock.advance(HeadsetCaptureUnit.callbackStall + 0.01)
        waitFor { stalls() == 2 }
        #expect(stalls() == 2)

        unit.stop()
    }

    @Test func converterFailureIsReportedAndSurvived() throws {
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)
        unit.makeConverter = { _, _ in nil }

        var events: [HeadsetCaptureEvent] = []
        let lock = NSLock()
        unit.onEvent = { event, _ in lock.withLock { events.append(event) } }

        let epoch = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: epoch)

        #expect(unit.isRunning)
        let failedCountAtStart = lock.withLock { events.filter { $0 == .converterFailed }.count }
        #expect(failedCountAtStart == 1)

        // Push frames, which will be dropped
        fake.push(samples: [0.1, 0.2, 0.3])
        Thread.sleep(forTimeInterval: 0.03)

        let failedCountAfterPush = lock.withLock { events.filter { $0 == .converterFailed }.count }
        #expect(failedCountAfterPush == 1)
        #expect(unit.isRunning)

        unit.stop()
    }

    @Test func startFailureTearsDown() throws {
        let fake = FakeHALDriver()
        fake.startError = NSError(domain: "test", code: -50)
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)

        let epoch = CaptureEpoch()
        var thrownError: HeadsetCaptureUnit.StartError?
        do {
            try unit.start(deviceUID: "test-uid", epoch: epoch)
        } catch let error as HeadsetCaptureUnit.StartError {
            thrownError = error
        } catch {
            Issue.record("Expected HeadsetCaptureUnit.StartError, got \(error)")
        }

        #expect(thrownError != nil)
        #expect(thrownError?.description.hasPrefix("headset_auhal_start=") == true)
        #expect(fake.stopCallCount >= 1)
        #expect(!unit.isRunning)
    }

    @Test func stopIsIdempotentAndEpochScoped() throws {
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)
        var events: [HeadsetCaptureEvent] = []
        var delivered: [Float] = []
        let lock = NSLock()
        unit.onEvent = { event, _ in lock.withLock { events.append(event) } }
        unit.onFrames = { chunk, _, _ in lock.withLock { delivered.append(contentsOf: chunk) } }

        let currentEpoch = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: currentEpoch)

        let otherEpoch = CaptureEpoch()
        unit.stop(epoch: otherEpoch)
        #expect(unit.isRunning)
        #expect(fake.stopCallCount == 0)
        #expect(lock.withLock { !events.contains(.stopped) })

        unit.stop(epoch: currentEpoch)
        #expect(!unit.isRunning)
        #expect(fake.stopCallCount == 1)
        let stoppedCount = lock.withLock { events.filter { $0 == .stopped }.count }
        #expect(stoppedCount == 1)

        // Second stop() does not call driver.stop again
        unit.stop()
        #expect(fake.stopCallCount == 1)
        let stoppedCount2 = lock.withLock { events.filter { $0 == .stopped }.count }
        #expect(stoppedCount2 == 1)

        // Frames pushed after stop are never delivered
        fake.push(samples: [0.1, 0.2, 0.3])
        Thread.sleep(forTimeInterval: 0.03)
        let deliveredAfterStop = lock.withLock { delivered.count }
        #expect(deliveredAfterStop == 0)
    }

    @Test func lateFramesFromAnOldEpochAreDropped() throws {
        let fake = FakeHALDriver()
        let unit = HeadsetCaptureUnit(driver: fake, workerInterval: 0.005)
        var deliveries: [(CaptureEpoch, [Float])] = []
        let lock = NSLock()
        unit.onFrames = { chunk, _, epoch in
            lock.withLock { deliveries.append((epoch, chunk)) }
        }

        let epochA = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: epochA)
        let sinkA = fake.renderSink!

        unit.stop()

        let epochB = CaptureEpoch()
        try unit.start(deviceUID: "test-uid", epoch: epochB)

        // Push buffer using sinkA (simulating a slot rendered under epoch A)
        let sineA = FakeHALDriver.sine(count: 4410, sampleRate: 44100)
        sineA.withUnsafeBufferPointer { buf in
            sinkA(buf.baseAddress!, buf.count, 0)
        }

        // Push buffer using current sink (epoch B)
        let sineB = FakeHALDriver.sine(count: 4410, sampleRate: 44100)
        fake.push(samples: sineB)

        let deadline = Date().addingTimeInterval(10.0)
        while Date() < deadline {
            let count = lock.withLock { deliveries.count }
            if count >= 1 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        let results = lock.withLock { deliveries }
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.0 === epochB })
        #expect(!results.contains { $0.0 === epochA })

        unit.stop()
    }
}
