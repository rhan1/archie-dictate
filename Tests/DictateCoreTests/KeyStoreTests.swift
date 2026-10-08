import Foundation
import Testing
import DictateCore

private final class KeyProbe: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var now: TimeInterval = 0
    func read(_ service: String) throws -> String {
        lock.withLock { calls += 1 }
        Thread.sleep(forTimeInterval: 1)
        return "fixture-key"
    }
    var count: Int { lock.withLock { calls } }
    var time: TimeInterval { lock.withLock { now } }
    func advance(to time: TimeInterval) { lock.withLock { now = time } }
}
private func waitFor(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
@Suite("KeyStore")
struct KeyStoreTests {
    @Test func slowReaderNeverBlocksCallerAndCachesOnce() async {
        let probe = KeyProbe()
        let store = KeyStore(reader: { try probe.read($0) })
        store.prefetch(services: ["fixture"])
        #expect(await waitFor { probe.count == 1 })
        let start = DispatchTime.now().uptimeNanoseconds
        let key = store.key(for: "fixture")
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("KEYSTORE_NONBLOCKING_MS=\(ms)")
        #expect(key == nil)
        #expect(ms < 50)
        #expect(store.missing(for: "fixture") == .pending)
        for _ in 0..<100 { #expect(store.key(for: "fixture") == nil) }
        store.prefetch(services: ["fixture", "fixture"])
        #expect(await waitFor { store.missing(for: "fixture") == nil })
        for _ in 0..<100 { #expect(store.key(for: "fixture") == "fixture-key") }
        #expect(probe.count == 1)
    }
    @Test func failureRetriesOnlyAfterSixtySeconds() async {
        let probe = KeyProbe()
        let store = KeyStore(reader: { _ in
            let count = probe.lock.withLock { probe.calls += 1; return probe.calls }
            if count < 3 { throw TranscriptionError.missingKey }
            return "retry-key"
        }, clock: { probe.time })
        #expect(store.key(for: "fixture") == nil)
        #expect(probe.count == 0)
        store.prefetch(services: ["fixture"])
        #expect(await waitFor { store.missing(for: "fixture") == .denied })
        probe.advance(to: 59.999)
        for _ in 0..<100 { #expect(store.key(for: "fixture") == nil) }
        #expect(probe.count == 1)
        probe.advance(to: 60)
        #expect(store.key(for: "fixture") == nil)
        #expect(await waitFor { probe.count == 2 && store.missing(for: "fixture") == .denied })
        probe.advance(to: 119.999)
        #expect(store.key(for: "fixture") == nil)
        #expect(probe.count == 2)
        probe.advance(to: 120)
        #expect(store.key(for: "fixture") == nil)
        #expect(await waitFor { store.key(for: "fixture") == "retry-key" })
        #expect(probe.count == 3)
    }
    @Test func blankReaderResultIsDenied() async {
        let store = KeyStore(reader: { _ in " \n" })
        store.prefetch(services: ["fixture"])
        #expect(await waitFor { store.missing(for: "fixture") == .denied })
        #expect(store.key(for: "fixture") == nil)
    }
}
