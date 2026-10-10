import CoreAudio
import Testing
@testable import DictateAppKit

@Suite("BluetoothProfileTests")
struct BluetoothProfileTests {
    private func observe(_ latch: inout ForeignHFPLatch, profile: String, engineAllocated: Bool, idle: Bool) -> Bool {
        latch.observe(profile: profile, engineAllocated: engineAllocated, idle: idle)
    }

    @Test func classifiesHeadsetRates() {
        #expect(BluetoothProfile.profile(transport: kAudioDeviceTransportTypeBluetooth, rate: 16_000) == "hfp")
        #expect(BluetoothProfile.profile(transport: kAudioDeviceTransportTypeBluetooth, rate: 44_100) == "a2dp")
        #expect(BluetoothProfile.profile(transport: kAudioDeviceTransportTypeBuiltIn, rate: 16_000) == "none")
    }

    @Test func foreignHFPNotesOncePerEpisode() {
        var latch = ForeignHFPLatch()
        #expect(observe(&latch, profile: "hfp", engineAllocated: false, idle: true))
        #expect(!observe(&latch, profile: "hfp", engineAllocated: false, idle: true))
        #expect(!observe(&latch, profile: "a2dp", engineAllocated: false, idle: true))
        #expect(observe(&latch, profile: "hfp", engineAllocated: false, idle: true))
    }

    @Test func dictateOwnHFPIsNotForeign() {
        var latch = ForeignHFPLatch()
        #expect(!observe(&latch, profile: "hfp", engineAllocated: true, idle: true))
        #expect(!observe(&latch, profile: "hfp", engineAllocated: false, idle: false))
        #expect(!observe(&latch, profile: "none", engineAllocated: false, idle: true))
        #expect(observe(&latch, profile: "hfp", engineAllocated: false, idle: true))
    }
}
