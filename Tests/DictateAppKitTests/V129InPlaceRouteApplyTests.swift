import AVFoundation
import CoreAudio
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

/// 1.29: an Archie conversation (⌘⌘) on a Bluetooth headset settles instead of looping. A same-device Bluetooth
/// route apply restarts the SAME engine in place; everything else rebuilds as on 1.28.
///
/// Hardware-free: the real `AudioRecorder` (lease, epochs, generation protocol, decision, tap tokens, converter,
/// feed, fallback, activation bookkeeping) runs its engine-arm apply against a fake engine through
/// `OfflineConversationEngine` — only the native AVAudioEngine calls are faked. No microphone, device or audio.
@Suite("V129InPlaceRouteApplyTests", .serialized)
struct V129InPlaceRouteApplyTests {
    typealias Bound = ConversationRouteReplacement.Bound
    static let sonyUID = "58-18-62-21-1C-6A:input"

    struct NativeError: Error {}

    /// One fake AVAudioEngine: its input node's tap, start and bound-device read-back.
    ///
    /// 1.29.2: the input node models the native format contract, not a decision. `hardware` (the device's input
    /// format) and `output` (the node's bus-0 output/client format) are separate mutable values; a nil-format tap
    /// leaves `output` as it is; an explicit tap format sets it; `start()` throws
    /// `NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)` iff they disagree (rate or channels). A new
    /// engine binds the then-current hardware format (`output == hardware`).
    final class FakeEngine: @unchecked Sendable {
        let id: Int
        private let lock = NSLock()
        private var _device: AudioDeviceID?
        private var _running = false
        private var _tap: AVAudioNodeTapBlock?
        private var _taps: [AVAudioNodeTapBlock] = []
        private(set) var installs = 0, removes = 0, starts = 0
        var removeError: Error?, installError: Error?, startError: Error?
        /// Runs inside `start()` before it returns (a stop racing the apply).
        var onStart: (() -> Void)?
        private var _hardware: AVAudioFormat
        private var _output: AVAudioFormat
        private var _tapFormats: [AVAudioFormat?] = []
        private var _startErrors: [NSError] = []
        private var _startTimes: [TimeInterval] = [], _removeTimes: [TimeInterval] = []

        init(id: Int, device: AudioDeviceID?, hardware: AVAudioFormat) {
            self.id = id
            _device = device
            _hardware = hardware
            _output = hardware
        }
        /// The device's current input (hardware) format; changing it leaves `output` stale.
        var hardware: AVAudioFormat {
            get { lock.withLock { _hardware } }
            set { lock.withLock { _hardware = newValue } }
        }
        /// The input node's bus-0 output (client) format.
        var output: AVAudioFormat {
            get { lock.withLock { _output } }
            set { lock.withLock { _output = newValue } }
        }
        /// The format each installTap asked for, in order (nil: the node's own).
        var tapFormats: [AVAudioFormat?] { lock.withLock { _tapFormats } }
        /// Every native format refusal `start()` returned, in order.
        var startErrors: [NSError] { lock.withLock { _startErrors } }
        /// 1.29.2 D1: uptime of every successful start / tap removal on this engine.
        var startTimes: [TimeInterval] { lock.withLock { _startTimes } }
        var removeTimes: [TimeInterval] { lock.withLock { _removeTimes } }
        static func agree(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
            a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
        }
        var device: AudioDeviceID? {
            get { lock.withLock { _device } }
            set { lock.withLock { _device = newValue } }
        }
        var running: Bool {
            get { lock.withLock { _running } }
            set { lock.withLock { _running = newValue } }
        }
        var counts: (installs: Int, removes: Int, starts: Int) { lock.withLock { (installs, removes, starts) } }
        /// Every tap block ever installed on this engine, in order (a stale one stays callable).
        var taps: [AVAudioNodeTapBlock] { lock.withLock { _taps } }
        var hasTap: Bool { lock.withLock { _tap != nil } }

        var native: EngineInputNative {
            EngineInputNative(
                formats: { self.lock.withLock { (self._hardware, self._output) } },
                installTap: { format, block in
                    try self.lock.withLock {
                        self.installs += 1
                        self._tapFormats.append(format)
                        if let e = self.installError { throw e }
                        if let format { self._output = format }      // an explicit tap format sets the bus
                        self._tap = block
                        self._taps.append(block)
                    }
                },
                removeTap: {
                    try self.lock.withLock {
                        self.removes += 1
                        if let e = self.removeError { throw e }
                        self._tap = nil
                        self._removeTimes.append(ProcessInfo.processInfo.systemUptime)
                    }
                },
                prepare: {},
                start: {
                    self.onStart?()
                    try self.lock.withLock {
                        self.starts += 1
                        if let e = self.startError { throw e }
                        guard Self.agree(self._hardware, self._output) else {
                            let e = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
                            self._startErrors.append(e)
                            throw e
                        }
                        self._running = true
                        self._startTimes.append(ProcessInfo.processInfo.systemUptime)
                    }
                },
                boundDevice: { self.device },
                isRunning: { self.running },
                deviceName: { "fake-engine-\(self.id)" })
        }

        /// Pushes one buffer through a tap this engine installed (index into `taps`; default the newest), stamped
        /// with host time `at` (uptime seconds; nil: no host time, as `offlineHeadsetBuffer` does).
        func deliver(_ buffer: AVAudioPCMBuffer, tap index: Int? = nil, at seconds: TimeInterval? = nil) {
            let taps = self.taps
            guard !taps.isEmpty else { return }
            let time = seconds.map { AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: $0)) }
                ?? AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate)
            taps[index ?? taps.count - 1](buffer, time)
        }
    }

    /// The fake route plus the engine factory the seam rebuilds through.
    final class Rig: @unchecked Sendable {
        private let lock = NSLock()
        private var _defaultDevice: AudioDeviceID? = 77
        private var _uids: [AudioDeviceID: String] = [77: V129InPlaceRouteApplyTests.sonyUID, 78: "AA-BB-CC-DD-EE-FF:input", 81: "BuiltInMicrophoneDevice"]
        private var _uidReadable = true
        private var _captureDevice: (AudioDeviceID) -> AudioDeviceID? = { $0 }
        private var _input: CaptureBridge.DefaultInput = .bluetooth
        private var _fingerprint = "headset:77:16000:1:1"
        private var _engines: [FakeEngine] = []
        private(set) var rebuilds = 0
        var rebuildError: Error?
        /// The device a newly built engine binds to (nil: the current default).
        var nextEngineDevice: AudioDeviceID??
        /// 1.29.2 D1: called (outside the rig lock) with every engine a rebuild creates, before it is used.
        var onNewEngine: ((FakeEngine) -> Void)?
        private var _hardware: AVAudioFormat

        init(hardware: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!) {
            _hardware = hardware
            _engines = [FakeEngine(id: 0, device: 77, hardware: hardware)]
        }
        /// The headset's current input format. Setting it changes ONLY the live engine's hardware side (its output
        /// bus keeps the old client format); a later rebuild binds this format.
        var hardware: AVAudioFormat {
            get { lock.withLock { _hardware } }
            set {
                let engine = lock.withLock { () -> FakeEngine in _hardware = newValue; return _engines.last! }
                engine.hardware = newValue
            }
        }
        var defaultDevice: AudioDeviceID? {
            get { lock.withLock { _defaultDevice } }
            set { lock.withLock { _defaultDevice = newValue } }
        }
        var input: CaptureBridge.DefaultInput {
            get { lock.withLock { _input } }
            set { lock.withLock { _input = newValue } }
        }
        var fingerprint: String {
            get { lock.withLock { _fingerprint } }
            set { lock.withLock { _fingerprint = newValue } }
        }
        var uidReadable: Bool {
            get { lock.withLock { _uidReadable } }
            set { lock.withLock { _uidReadable = newValue } }
        }
        func setUID(_ uid: String, for device: AudioDeviceID) { lock.withLock { _uids[device] = uid } }
        func setCaptureDevice(_ resolve: @escaping (AudioDeviceID) -> AudioDeviceID?) {
            lock.withLock { _captureDevice = resolve }
        }
        var engine: FakeEngine { lock.withLock { _engines.last! } }
        var engines: [FakeEngine] { lock.withLock { _engines } }

        func rebuild() throws {
            let fresh = try lock.withLock { () -> FakeEngine in
                if let e = rebuildError { throw e }
                rebuilds += 1
                let device: AudioDeviceID? = nextEngineDevice ?? _defaultDevice
                let engine = FakeEngine(id: _engines.count, device: device, hardware: _hardware)
                _engines.append(engine)
                return engine
            }
            onNewEngine?(fresh)
        }

        var probe: CaptureRouteProbe {
            var probe = CaptureRouteProbe(
                eligibility: { (self.input, false) },          // no built-in bridge: the headset carries directly
                defaultInput: { self.defaultDevice },
                uid: { device in self.lock.withLock { self._uidReadable ? self._uids[device] : nil } },
                captureDevice: { device in self.lock.withLock { self._captureDevice(device) } },
                defaultInputName: { "fake-default" },
                outputIsBluetooth: { self.input == .bluetooth })
            probe.effectiveRoute = { self.fingerprint }
            return probe
        }
    }

    final class States: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [ConversationCaptureState] = []
        func append(_ s: ConversationCaptureState) { lock.withLock { states.append(s) } }
        var all: [ConversationCaptureState] { lock.withLock { states } }
        var settled: [ConversationCaptureState] {
            all.filter { if case .routeSettled = $0 { return true } else { return false } }
        }
    }

    struct Session {
        let recorder: AudioRecorder
        let rig: Rig
        let states: States
        let broker: CaptureLeaseBroker
    }

    /// An engine-arm Bluetooth conversation started through the seam (production activation bookkeeping).
    static func start(_ rig: Rig = Rig(), backend: HeadsetBackend = .engine, broker: CaptureLeaseBroker = CaptureLeaseBroker(),
                      at time: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Session {
        let engineArm = backend == .engine
        let log = V61CaptureLifetimeTests.Log()
        let builtin = V61CaptureLifetimeTests.FakeBuiltin("v129.builtin", log: log)
        let headset = V61CaptureLifetimeTests.FakeHeadset("v129.headset", log: log)
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: backend, broker: broker, route: rig.probe)
        recorder.kind = .conversation
        let states = States()
        recorder.onConversationCaptureState = { [weak recorder] state in
            states.append(state)
            // Re-entrant sink: the host may query the recorder from inside the callback (no lock is held).
            _ = recorder?.currentLease
            _ = recorder?.conversationApplyNote
        }
        let make: (CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit = { [weak recorder] _ in
            CaptureInputUnit(start: { try recorder?.offlineInstallConvertingTapAndStart() }, dispose: {})
        }
        recorder.offlineConversationEngine = OfflineConversationEngine(
            native: { rig.engine.native }, rebuild: { try rig.rebuild() }, make: make)
        // The AUHAL arm never starts an engine: its fixture start touches no engine node.
        try recorder.offlineStartInput(at: time, note: { _ in },
                                       make: engineArm ? make : { _ in CaptureInputUnit(start: {}, dispose: {}) })
        return Session(recorder: recorder, rig: rig, states: states, broker: broker)
    }

    /// One admitted generation (the engine's own HFP self-stop by default) and its apply.
    @discardableResult
    static func apply(_ s: Session, invalidated: Bool = true) throws -> Bool {
        s.recorder.observeConversationRoute(invalidated: invalidated)
        return try s.recorder.reconfigureConversationInput(at: ProcessInfo.processInfo.systemUptime)
    }

    static func sine(rate: Double, channels: AVAudioChannelCount, frames: Int, amplitude: Float = 0.3) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(channels) {
            let data = buffer.floatChannelData![c]
            for i in 0..<frames { data[i] = amplitude * sin(2 * .pi * 440 * Float(i) / Float(rate)) }
        }
        return buffer
    }

    static func outcome(_ note: String) -> String {
        guard let field = note.split(separator: " ").first(where: { $0.hasPrefix("conv_apply=") }) else { return "none" }
        return field == "conv_apply=in_place" ? "I" : "R"
    }

    static func field(_ name: String, _ note: String) -> String? {
        note.split(separator: " ").first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) }
    }

    // MARK: - T-1 decision (pure)

    @Test func decisionSameBluetoothInputRestartsInPlaceUntilTheCap() {
        let sony = Bound(device: 77, uid: Self.sonyUID)
        let counts = (0...3).map {
            ConversationRouteReplacement.decide(bluetooth: true, bound: sony, observed: sony, engineDevice: 77, consecutive: $0)
        }
        #expect(counts == [.inPlace, .inPlace, .inPlace, .rebuild(reason: "cap")])
        // RED twin: 49b5b51's policy ("always rebuild") on the IDENTICAL inputs fails the in-place predicate.
        func alwaysRebuild(bluetooth: Bool, bound: Bound?, observed: Bound?, engineDevice: AudioDeviceID?, consecutive: Int)
            -> ConversationRouteReplacement.Decision { .rebuild(reason: "always") }
        let red = alwaysRebuild(bluetooth: true, bound: sony, observed: sony, engineDevice: 77, consecutive: 0)
        #expect(red != .inPlace)
        print("F1 RED T-1 always_rebuild_policy decision=rebuild(always) predicate_in_place=FAIL")
        print("F1 GREEN T-1 decisions=\(counts.map { $0 == .inPlace ? "I" : "R" }.joined()) cap_at=3")
    }

    @Test func decisionEveryUncertainOrDifferentInputRebuilds() {
        let sony = Bound(device: 77, uid: Self.sonyUID)
        func d(_ bt: Bool = true, bound: Bound?? = .some(sony), observed: Bound?? = .some(sony), engine: AudioDeviceID?? = .some(77),
               n: Int = 0) -> String {
            switch ConversationRouteReplacement.decide(bluetooth: bt, bound: bound ?? nil, observed: observed ?? nil,
                                                       engineDevice: engine ?? nil, consecutive: n) {
            case .inPlace: return "in_place"
            case .rebuild(let reason): return reason
            }
        }
        let cases: [(String, String)] = [
            ("not_bluetooth", d(false)),
            ("no_bound", d(bound: .some(nil))),
            ("unknown_read", d(observed: .some(nil))),
            ("unknown_read", d(observed: .some(Bound(device: 0, uid: Self.sonyUID)))),
            ("unknown_read", d(observed: .some(Bound(device: 77, uid: "")))),
            ("engine_unreadable", d(engine: .some(nil))),
            ("engine_unreadable", d(engine: .some(0))),
            ("device_changed", d(observed: .some(Bound(device: 78, uid: Self.sonyUID)))),
            ("device_changed", d(observed: .some(Bound(device: 77, uid: "58-18-62-21-1C-6B:input")))),
            ("engine_bound_elsewhere", d(engine: .some(81))),
            ("cap", d(n: 3)),
        ]
        for (expected, actual) in cases { #expect(actual == expected) }
        // A colon-containing UID is compared whole and rendered quoted, never split.
        let note = ConversationRouteReplacement.note(inPlace: true, reason: "same_device", bound: sony, observed: sony,
            engineDevice: 77, engineRunning: false, consecutive: 1, generation: 1)
        #expect(note.contains("bound=77/\"58-18-62-21-1C-6A:input\""))
        print("F1 CONTROL T-1c \(cases.map { $0.1 }.joined(separator: ","))")
    }

    @Test func bindingNeedsTheEnginesOwnReadBack() {
        let sony = Bound(device: 77, uid: Self.sonyUID)
        #expect(ConversationRouteReplacement.binding(observed: sony, engineDevice: 77) == sony)
        #expect(ConversationRouteReplacement.binding(observed: sony, engineDevice: 81) == nil)   // default B, engine A
        #expect(ConversationRouteReplacement.binding(observed: sony, engineDevice: nil) == nil)
        #expect(ConversationRouteReplacement.binding(observed: nil, engineDevice: 77) == nil)
        // RED twin: a default-only binding records B while the engine is still bound to A.
        func defaultOnly(observed: Bound?, engineDevice: AudioDeviceID?) -> Bound? { observed }
        let falseBound = defaultOnly(observed: sony, engineDevice: 81) != nil
        #expect(falseBound)
        print("F1 RED T-2b default_only_binding false_bound=1 => FAIL")
        print("F1 GREEN T-2b binding agree=77 disagree=nil unreadable=nil unknown=nil")
    }

    // MARK: - T-2 the real apply

    @Test func sameDeviceApplyRestartsTheSameEngineInPlace() throws {
        let s = try Self.start()
        let engine = s.rig.engine
        engine.running = false                                     // the engine stopped itself (HFP bring-up)
        let lease = try #require(s.recorder.currentLease)
        #expect(engine.counts == (1, 0, 1))
        // Old-tap PCM while the generation is pending is rejected.
        s.recorder.observeConversationRoute(invalidated: true)
        let before = s.recorder.retainedFrameCount
        engine.deliver(Self.sine(rate: 16_000, channels: 1, frames: 1_600), tap: 0)
        #expect(s.recorder.retainedFrameCount == before)
        let applied = try s.recorder.reconfigureConversationInput(at: ProcessInfo.processInfo.systemUptime)
        #expect(applied)
        let note = s.recorder.conversationApplyNote
        let sameEngine = s.rig.engine === engine
        #expect(sameEngine)
        #expect(s.rig.rebuilds == 0)
        #expect(engine.counts == (2, 1, 2))                        // one removal, one new tap, one start
        #expect(s.recorder.currentLease === lease)
        #expect(s.states.all == [.routeChangePending(generation: 1), .routeSettled(generation: 1, voiceProcessing: "unavailable")])
        #expect(note.hasPrefix("conv_apply=in_place reason=same_device bound=77/\"\(Self.sonyUID)\" consecutive=1 gen=1"))
        #expect(note.contains("engine_running=0"))
        // The old tap stays fenced after settle; the new tap delivers current PCM.
        engine.deliver(Self.sine(rate: 16_000, channels: 1, frames: 1_600), tap: 0)
        let stale = s.recorder.retainedFrameCount - before
        engine.deliver(Self.sine(rate: 16_000, channels: 1, frames: 1_600))
        let current = s.recorder.retainedFrameCount - before
        #expect(stale == 0)
        #expect(current > 0)
        _ = s.recorder.stop()
        print("F1 GREEN T-2 same_engine=\(sameEngine ? 1 : 0) rebuilds=\(s.rig.rebuilds) installs=2 removes=1 lease_same=1 settled_once=1 stale_pcm=\(stale) current_pcm=\(current) note=\(note)")
    }

    /// Only the three CoreAudio property reads are faked. Both recorder call sites execute
    /// AudioDevices.captureDevice, including on every activation after a rebuild.
    final class CaptureProperties: @unchecked Sendable {
        private let lock = NSLock()
        private var transport: UInt32? = kAudioDeviceTransportTypeAggregate
        private var members: [AudioObjectID]? = [90, 84]
        private var streams: [AudioObjectID: Int] = [90: 1, 84: 0, 91: 1]
        private var reads: [String] = []

        func setTransport(_ value: UInt32?) { lock.withLock { transport = value } }
        func setMembers(_ value: [AudioObjectID]?) { lock.withLock { members = value } }
        func setStreams(_ value: Int?, for device: AudioObjectID) { lock.withLock { streams[device] = value } }
        var queries: [String] { lock.withLock { reads } }
        var reader: AudioDevices.CaptureDevicePropertyReader {
            AudioDevices.CaptureDevicePropertyReader(
                transport: { device in self.lock.withLock {
                    self.reads.append("transport:\(device)")
                    return device == 142 ? self.transport : kAudioDeviceTransportTypeBluetooth
                } },
                activeSubdevices: { device in self.lock.withLock {
                    self.reads.append("members:\(device)")
                    return device == 142 ? self.members : nil
                } },
                inputStreamCount: { device in self.lock.withLock {
                    self.reads.append("streams:\(device)")
                    return self.streams[device]
                } })
        }
    }

    static func resolverSession(_ properties: CaptureProperties, engineDevice: AudioDeviceID = 142) throws -> Session {
        let rig = Rig()
        rig.defaultDevice = 90
        rig.setUID(sonyUID, for: 90)
        rig.engine.device = engineDevice
        rig.nextEngineDevice = .some(engineDevice)
        let reader = properties.reader
        rig.setCaptureDevice { AudioDevices.captureDevice(of: $0, reading: reader) }
        return try start(rig)
    }

    /// Assert the resolver result AND the real activation/apply decision. The successful single-input
    /// fixture is the positive control for the rejection fixtures; none injects a resolved ID or nil.
    static func rejectedResolution(_ label: String, _ properties: CaptureProperties,
                                   expectedResolution: AudioDeviceID? = nil) throws {
        let resolved = AudioDevices.captureDevice(of: 142, reading: properties.reader)
        let s = try resolverSession(properties)
        defer { _ = s.recorder.stop() }
        let engine = s.rig.engine
        #expect(try apply(s))
        let note = s.recorder.conversationApplyNote
        print("FR1-B \(label) actual resolved=\(resolved.map(String.init) ?? "nil") rebuilds=\(s.rig.rebuilds) note=\(note) queries=\(properties.queries.joined(separator: ","))")
        #expect(resolved == expectedResolution)
        #expect(note.hasPrefix("conv_apply=rebuild reason=no_bound bound=nil"))
        #expect(s.rig.rebuilds == 1)
        #expect(s.rig.engine !== engine)
    }

    @Test func fr1DirectNonAggregateBindsTheDefault() throws {
        let p = CaptureProperties()
        let s = try Self.resolverSession(p, engineDevice: 90)
        defer { _ = s.recorder.stop() }
        let engine = s.rig.engine
        #expect(try Self.apply(s))
        let note = s.recorder.conversationApplyNote
        print("FR1-B direct actual rebuilds=\(s.rig.rebuilds) note=\(note) queries=\(p.queries.joined(separator: ","))")
        #expect(note.hasPrefix("conv_apply=in_place reason=same_device bound=90/"))
        #expect(s.rig.rebuilds == 0 && s.rig.engine === engine)
        #expect(!p.queries.isEmpty && p.queries.allSatisfy { $0 == "transport:90" })
    }

    @Test func fr1SingleInputAggregateBindsAndSecondGenerationAppliesInPlace() throws {
        let p = CaptureProperties() // 142 = {90 input, 84 output}; sampled default = 90
        let s = try Self.resolverSession(p)
        defer { _ = s.recorder.stop() }
        let engine = s.rig.engine
        #expect(try Self.apply(s))
        #expect(try Self.apply(s))
        let note = s.recorder.conversationApplyNote
        print("FR1-B single_input actual rebuilds=\(s.rig.rebuilds) note=\(note) queries=\(p.queries.joined(separator: ","))")
        #expect(note.hasPrefix("conv_apply=in_place reason=same_device bound=90/\"\(Self.sonyUID)\" consecutive=2 gen=2"))
        #expect(s.rig.rebuilds == 0 && s.rig.engine === engine)
        #expect(p.queries == Array(repeating: ["transport:142", "members:142", "streams:90", "streams:84"], count: 5).flatMap { $0 })
    }

    @Test func fr1TwoInputAggregateRejectsBinding() throws {
        let p = CaptureProperties()
        p.setMembers([90, 91, 84])
        try Self.rejectedResolution("two_inputs", p)
        #expect(p.queries.contains("streams:84")) // even after two inputs, every member is queried
    }

    @Test func fr1ZeroInputAggregateRejectsBinding() throws {
        let p = CaptureProperties()
        p.setStreams(0, for: 90)
        try Self.rejectedResolution("zero_inputs", p)
    }

    @Test func fr1FailedMemberStreamQueryRejectsBinding() throws {
        let p = CaptureProperties()
        p.setMembers([90, 91, 84])
        p.setStreams(nil, for: 91) // a9888ff silently drops 91 and incorrectly binds 90
        try Self.rejectedResolution("failed_member", p)
        #expect(p.queries.contains("streams:91"))
    }

    @Test func fr1FailedTransportReadRejectsBinding() throws {
        let p = CaptureProperties()
        p.setTransport(nil)
        try Self.rejectedResolution("failed_transport", p)
        #expect(p.queries.allSatisfy { $0 == "transport:142" })
    }

    @Test func fr1FailedSubdeviceListReadRejectsBinding() throws {
        let p = CaptureProperties()
        p.setMembers(nil)
        try Self.rejectedResolution("failed_members", p)
        #expect(!p.queries.contains { $0.hasPrefix("streams:") })
    }

    @Test func fr1EmptySubdeviceListRejectsBinding() throws {
        let p = CaptureProperties()
        p.setMembers([])
        try Self.rejectedResolution("empty_members", p)
    }

    @Test func fr1AggregateInputDifferentFromDefaultRejectsBinding() throws {
        let p = CaptureProperties()
        p.setMembers([91, 84])
        try Self.rejectedResolution("different_input", p, expectedResolution: 91)
    }

    @Test func fr1AggregateMembershipChangeBetweenActivationAndApplyRebuilds() throws {
        let p = CaptureProperties()
        let s = try Self.resolverSession(p) // activation binds 90 from {90 input, 84 output}
        defer { _ = s.recorder.stop() }
        let engine = s.rig.engine
        p.setMembers([91, 84]) // same aggregate ID and sampled default, different actual input
        #expect(try Self.apply(s))
        let note = s.recorder.conversationApplyNote
        print("FR1-B membership_change actual rebuilds=\(s.rig.rebuilds) note=\(note) queries=\(p.queries.joined(separator: ","))")
        #expect(note.hasPrefix("conv_apply=rebuild reason=engine_bound_elsewhere bound=90/"))
        #expect(note.contains("engine_dev=91"))
        #expect(s.rig.rebuilds == 1 && s.rig.engine !== engine)
        #expect(p.queries.contains("streams:90") && p.queries.contains("streams:91"))
    }

    @Test func runningEngineAndAWatchOnlyRateChangeAlsoApplyInPlace() throws {
        let s = try Self.start()
        let engine = s.rig.engine
        #expect(engine.running)                                    // still running: a watch-only output-rate change
        s.rig.fingerprint = "headset:77:16000:1:1 out=48000"
        try Self.apply(s, invalidated: false)
        let note = s.recorder.conversationApplyNote
        #expect(Self.outcome(note) == "I")
        #expect(note.contains("engine_running=1"))
        #expect(s.rig.engine === engine && s.rig.rebuilds == 0)
        #expect(s.states.settled == [.routeSettled(generation: 1, voiceProcessing: "unavailable")])
        _ = s.recorder.stop()
        print("F1 GREEN T-2r running_engine=1 watch_only_change=1 outcome=in_place rebuilds=0")
    }

    @Test func activationDisagreementLeavesNoBoundAndRebuilds() throws {
        let rig = Rig()
        rig.engine.device = 81                                     // engine A still on the built-in, default is the Sony
        let s = try Self.start(rig)
        try Self.apply(s)
        let first = s.recorder.conversationApplyNote
        #expect(first.hasPrefix("conv_apply=rebuild reason=no_bound bound=nil consecutive=0 gen=1"))
        #expect(s.rig.rebuilds == 1)
        // The rebuilt engine reads back the Sony: that activation records it, and the next apply is in place.
        try Self.apply(s)
        let second = s.recorder.conversationApplyNote
        #expect(Self.outcome(second) == "I")
        #expect(s.rig.rebuilds == 1)
        _ = s.recorder.stop()
        print("F1 GREEN T-2b activation_disagree=rebuild(no_bound) next_activation_agrees=in_place")
    }

    @Test func differentBluetoothInputAndBuiltinSwitchRebuild() throws {
        let s = try Self.start()
        s.rig.defaultDevice = 78                                   // a second Bluetooth headset
        s.rig.fingerprint = "headset:78:16000:1:1"
        try Self.apply(s, invalidated: false)
        let changed = s.recorder.conversationApplyNote
        #expect(changed.hasPrefix("conv_apply=rebuild reason=device_changed"))
        #expect(s.rig.rebuilds == 1)
        s.rig.input = .builtin                                     // the MacBook microphone
        s.rig.defaultDevice = 81
        s.rig.fingerprint = "builtin:81:48000:1:2"
        try Self.apply(s, invalidated: false)
        let builtin = s.recorder.conversationApplyNote
        #expect(builtin.hasPrefix("conv_apply=rebuild reason=not_bluetooth"))
        #expect(s.rig.rebuilds == 2)
        #expect(s.states.settled.count == 2)
        _ = s.recorder.stop()
        print("F1 CONTROL T-2c other_bt=\(Self.field("reason", changed)!) builtin=\(Self.field("reason", builtin)!) rebuilds=2 settled=2")
    }

    @Test func auhalArmNeverTouchesTheEngineSeam() throws {
        let rig = Rig()
        let s = try Self.start(rig, backend: .auhal)
        let engine = rig.engine
        try Self.apply(s)
        #expect(engine.counts == (0, 0, 0))
        #expect(rig.rebuilds == 0)
        #expect(s.recorder.conversationApplyNote == "none")
        #expect(s.states.settled.count == 1)
        _ = s.recorder.stop()
        print("F1 CONTROL T-2a auhal_arm engine_ops=0 conv_apply=none settled=1")
    }

    // MARK: - T-3 the consecutive cap (a local fallback policy, not a generation bound)

    @Test func capRebuildsAfterThreeConsecutiveInPlaceApplies() throws {
        let s = try Self.start()
        var pattern = "", counts: [String] = []
        for _ in 0..<8 {
            try Self.apply(s)
            let note = s.recorder.conversationApplyNote
            pattern += Self.outcome(note)
            counts.append(Self.field("consecutive", note) ?? "?")
        }
        #expect(pattern == "IIIRIIIR")
        #expect(counts == ["1", "2", "3", "0", "1", "2", "3", "0"])
        // A real device change resets the count; so does stop.
        try Self.apply(s)                                          // I (1)
        s.rig.setUID("58-18-62-21-1C-6A:input2", for: 77)
        try Self.apply(s)                                          // R device_changed (0)
        let reset = s.recorder.conversationApplyNote
        try Self.apply(s)                                          // I (1)
        let after = s.recorder.conversationApplyNote
        #expect(reset.contains("reason=device_changed") && reset.contains("consecutive=0"))
        #expect(Self.outcome(after) == "I" && Self.field("consecutive", after) == "1")
        _ = s.recorder.stop()
        print("F1 GREEN T-3 pattern=\(pattern) counts=\(counts.joined(separator: ",")) device_change_resets=1")
    }

    // MARK: - T-4 failures fall through to today's rebuild in the same apply

    @Test func tapRemovalFailureRebuildsWithoutRetappingThatNode() throws {
        let s = try Self.start()
        let old = s.rig.engine
        old.removeError = NativeError()
        try Self.apply(s)
        let note = s.recorder.conversationApplyNote
        #expect(note.hasPrefix("conv_apply=rebuild reason=remove_failed"))
        #expect(note.contains("err="))
        #expect(old.counts.installs == 1)                          // never retapped after the failed removal
        #expect(s.rig.rebuilds == 1)
        #expect(s.rig.engine !== old && s.rig.engine.counts == (1, 0, 1))
        #expect(s.states.settled == [.routeSettled(generation: 1, voiceProcessing: "unavailable")])
        let before = s.recorder.retainedFrameCount
        s.rig.engine.deliver(Self.sine(rate: 16_000, channels: 1, frames: 1_600))
        let current = s.recorder.retainedFrameCount - before
        #expect(current > 0)
        // The rebuilt engine's own activation binds it, so the next apply is in place again.
        try Self.apply(s)
        #expect(Self.outcome(s.recorder.conversationApplyNote) == "I")
        _ = s.recorder.stop()
        print("F1 GREEN T-4a remove_failed install_after_remove_failure=0 rebuilds=1 settled_once=1 current_pcm=\(current)")
    }

    @Test func throwingRetapOrStartTearsDownAndRebuildsOnce() throws {
        for failing in ["install", "start"] {
            let s = try Self.start()
            let old = s.rig.engine
            if failing == "install" { old.installError = NativeError() } else { old.startError = NativeError() }
            try Self.apply(s)
            let note = s.recorder.conversationApplyNote
            #expect(note.hasPrefix("conv_apply=rebuild reason=in_place_failed"))
            #expect(Self.field("consecutive", note) == "0")
            #expect(s.rig.rebuilds == 1)
            #expect(!old.hasTap)                                   // the partial tap was removed by the teardown
            #expect(s.states.settled == [.routeSettled(generation: 1, voiceProcessing: "unavailable")])
            let before = s.recorder.retainedFrameCount
            s.rig.engine.deliver(Self.sine(rate: 16_000, channels: 1, frames: 1_600))
            #expect(s.recorder.retainedFrameCount > before)
            _ = s.recorder.stop()
            print("F1 GREEN T-4b \(failing)_throws fallback=rebuild rebuilds=1 settled_once=1 partial_tap_left=0 current_pcm=1")
        }
    }

    @Test func failedRebuildAfterFailedRetapKeepsTodaysError() throws {
        let s = try Self.start()
        s.rig.engine.startError = NativeError()
        s.rig.rebuildError = NativeError()
        #expect(throws: NativeError.self) { try Self.apply(s) }
        #expect(s.states.settled.isEmpty)
        _ = s.recorder.stop()
        print("F1 CONTROL T-4c rebuild_also_fails settled=0 error=thrown (applyPendingConversationDeviceChange stops, as 1.28)")
    }

    @Test func nilAudioUnitIsUnknownAndRebuilds() throws {
        let s = try Self.start()
        s.rig.engine.device = nil                                  // no input unit / unreadable read-back
        try Self.apply(s)
        let note = s.recorder.conversationApplyNote
        #expect(note.hasPrefix("conv_apply=rebuild reason=engine_unreadable"))
        #expect(s.rig.rebuilds == 1)
        _ = s.recorder.stop()
        print("F1 CONTROL T-4d nil_unit reason=engine_unreadable rebuilds=1")
    }

    // MARK: - T-5 unknown reads take today's path

    @Test func unknownDefaultReadRebuildsThenAKnownBindingRestoresInPlace() throws {
        let s = try Self.start()
        s.rig.uidReadable = false
        try Self.apply(s)
        let unknown = s.recorder.conversationApplyNote
        #expect(unknown.hasPrefix("conv_apply=rebuild reason=unknown_read"))
        #expect(s.rig.rebuilds == 1)
        #expect(s.states.all.count == 2)                           // no synthetic generation from the settle
        // That activation could not read the UID either: nothing bound, so the next apply rebuilds as well.
        try Self.apply(s)
        #expect(s.recorder.conversationApplyNote.hasPrefix("conv_apply=rebuild reason=no_bound"))
        s.rig.uidReadable = true
        try Self.apply(s)                                          // reads recovered: this rebuild's activation binds
        try Self.apply(s)
        #expect(Self.outcome(s.recorder.conversationApplyNote) == "I")
        _ = s.recorder.stop()
        print("F1 GREEN T-5 unknown_read=rebuild unknown_equals_same=0 recovered_binding=in_place")
    }

    // MARK: - T-b1 stale conversion and the 24 kHz contract

    @Test func stalePausedConversionIsNeverDeliveredAfterApplyOrStop() throws {
        let s = try Self.start()
        let engine = s.rig.engine
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        final class Gate: @unchecked Sendable { let lock = NSLock(); var armed = false }
        let gate = Gate()
        // Pause a buffer inside the real `consume`, after its tap token was accepted, at the native conversion
        // boundary (outside the recorder lock).
        s.recorder.headsetNative.before = { stage in
            guard stage == "output_buffer", gate.lock.withLock({ defer { gate.armed = false }; return gate.armed }) else { return }
            entered.signal()
            resume.wait()
        }
        func paused(_ during: () throws -> Void) rethrows -> Int {
            gate.lock.withLock { gate.armed = true }
            let done = DispatchSemaphore(value: 0)
            let tap = engine.taps.count - 1
            DispatchQueue.global().async {
                engine.deliver(Self.sine(rate: 16_000, channels: 1, frames: 1_600), tap: tap)
                done.signal()
            }
            #expect(entered.wait(timeout: .now() + 5) == .success)
            try during()
            let base = s.recorder.retainedFrameCount            // after the apply/stop, before the paused buffer resumes
            resume.signal()
            #expect(done.wait(timeout: .now() + 5) == .success)
            return s.recorder.retainedFrameCount - base
        }
        let staleAfterApply = try paused { try Self.apply(s) }
        #expect(Self.outcome(s.recorder.conversationApplyNote) == "I")
        let base = s.recorder.retainedFrameCount
        engine.deliver(Self.sine(rate: 16_000, channels: 1, frames: 1_600))
        let current = s.recorder.retainedFrameCount - base
        let staleAfterStop = paused { _ = s.recorder.stop() }
        #expect(staleAfterApply == 0)
        #expect(current > 0)
        #expect(staleAfterStop == 0)
        #expect(s.recorder.retainedFrameCount == 0)
        print("F1 CONTROL T-b1 stale_delivered=\(staleAfterApply) current_delivered=\(current) after_stop_delivered=\(staleAfterStop)")
    }

    @Test func retappedConversationDelivers24kMonoFrom16kMonoAnd48kStereo() throws {
        for (rate, channels) in [(16_000.0, AVAudioChannelCount(1)), (48_000.0, AVAudioChannelCount(2))] {
            let rig = Rig(hardware: AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!)
            let t0 = ProcessInfo.processInfo.systemUptime - 3
            let s = try Self.start(rig, at: t0)
            final class Chunks: @unchecked Sendable {
                let lock = NSLock(); var pcm: [Int16] = []
                func add(_ c: [Int16]) { lock.withLock { pcm += c } }
            }
            let chunks = Chunks()
            s.recorder.onPCMChunk = { chunks.add($0) }
            try Self.apply(s)
            #expect(Self.outcome(s.recorder.conversationApplyNote) == "I")
            let base = s.recorder.retainedFrameCount
            let per = Int(rate / 10)
            for i in 0..<10 {                                       // 1 s, contiguous host times after the boundary
                rig.engine.deliver(Self.sine(rate: rate, channels: channels, frames: per), at: t0 + 1 + Double(i) * 0.1)
            }
            s.recorder.offlineDrainPCM()
            let kept = s.recorder.retainedFrameCount - base
            let pcm = chunks.lock.withLock { chunks.pcm }
            // 24 kHz mono: one second in is 24 000 frames out, less the resampler's held-back tail.
            #expect(kept >= 23_500 && kept <= 24_000)
            #expect(pcm.count % AudioRecorder.chunkSamples == 0 && pcm.count >= 21_600)
            let peak = pcm.map { abs(Int($0)) }.max() ?? 0
            #expect(peak > 5_000 && peak < 12_000)                // 0.3 full-scale sine, finite, not clipped or silent
            _ = s.recorder.stop()
            print("F1 GREEN T-b1c in=\(Int(rate))Hz/\(channels)ch out_frames_1s=\(kept) chunks=\(pcm.count / AudioRecorder.chunkSamples) peak=\(peak)")
        }
    }

    // MARK: - T-vp

    @Test func inPlaceKeepsTheVoiceProcessingVerdictRebuildReevaluates() throws {
        let s = try Self.start()                                   // VP requested; Bluetooth refuses it: unavailable
        try Self.apply(s)
        #expect(Self.outcome(s.recorder.conversationApplyNote) == "I")
        let inPlace = s.states.settled.last
        #expect(inPlace == .routeSettled(generation: 1, voiceProcessing: "unavailable"))
        // Rebuild control: the policy re-evaluates (Bluetooth: unavailable; prefs off: off).
        s.recorder.conversationVoiceProcessingEnabled = false
        s.rig.defaultDevice = 78
        s.rig.fingerprint = "headset:78:16000:1:1"
        try Self.apply(s, invalidated: false)
        #expect(s.recorder.conversationApplyNote.hasPrefix("conv_apply=rebuild reason=device_changed"))
        #expect(s.states.settled.last == .routeSettled(generation: 2, voiceProcessing: "off"))
        _ = s.recorder.stop()
        print("F1 GREEN T-vp in_place_settled_vp=unavailable rebuild_reevaluated_vp=off")
    }

    // MARK: - T-c2 release window

    @Test func inPlaceApplyNeverStampsTheBluetoothRelease() async throws {
        let broker = CaptureLeaseBroker()
        let s = try Self.start(broker: broker)
        try Self.apply(s)                                          // in place
        try Self.apply(s)                                          // in place; its bridge reads the release age
        #expect(Self.outcome(s.recorder.conversationApplyNote) == "I")
        let retap = s.recorder.classificationNote
        #expect(retap.hasSuffix("since_release_ms=-"))             // no retap ever stamped a release
        _ = s.recorder.stop()
        _ = await s.recorder.awaitRelease()
        // Fresh recorder B: no release history of its own.
        let b = try Self.start(Rig(), broker: broker)
        try Self.apply(b)
        let fresh = b.recorder.classificationNote
        #expect(fresh.hasSuffix("since_release_ms=-"))
        _ = b.recorder.stop()
        _ = await b.recorder.awaitRelease()
        // Same recorder restarted: its own completed teardown's age (stamped by stop, not by the retaps).
        let rig = Rig()
        let make: (CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit = { [weak r = s.recorder] _ in
            CaptureInputUnit(start: { try r?.offlineInstallConvertingTapAndStart() }, dispose: {})
        }
        s.recorder.offlineConversationEngine = OfflineConversationEngine(native: { rig.engine.native }, rebuild: { try rig.rebuild() }, make: make)
        try s.recorder.offlineStartInput(at: ProcessInfo.processInfo.systemUptime, note: { _ in }, make: make)
        try Self.apply(Session(recorder: s.recorder, rig: rig, states: s.states, broker: broker))
        let own = s.recorder.classificationNote
        let age = Int(own.split(separator: "=").last.map(String.init) ?? "") ?? -1
        #expect(age >= 0 && age < 5_000)
        _ = s.recorder.stop()
        print("F1 CONTROL T-c2 retap_stamps_release=0 fresh_B=\(fresh) same_recorder=\(own)")
    }

    // MARK: - stop racing an apply

    @Test func stopRacingAnInPlaceApplyNeverSettlesOrReactivates() async throws {
        let broker = CaptureLeaseBroker()
        let s = try Self.start(broker: broker)
        let engine = s.rig.engine
        engine.onStart = { [weak recorder = s.recorder] in
            engine.onStart = nil
            _ = recorder?.stop()                                   // the conversation ends mid-retap
        }
        #expect(throws: CancellationError.self) { try Self.apply(s) }
        #expect(s.states.settled.isEmpty)
        #expect(s.recorder.currentLease == nil)
        let state = await s.recorder.awaitRelease()
        #expect(state == .released)
        // The retapped (old-session) tap delivers nothing; the next session owns its own binding and PCM.
        engine.deliver(Self.sine(rate: 16_000, channels: 1, frames: 1_600))
        #expect(s.recorder.retainedFrameCount == 0)
        let next = try Self.start(Rig(), broker: broker)
        try Self.apply(next)
        #expect(Self.outcome(next.recorder.conversationApplyNote) == "I")
        _ = next.recorder.stop()
        print("F1 CONTROL T-race stop_during_retap settled=0 lease_released=1 old_pcm_after_stop=0 next_session=in_place")
    }
}
