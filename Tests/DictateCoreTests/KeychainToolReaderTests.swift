import Foundation
import Testing
@testable import DictateCore

@Suite("KeychainToolReader")
struct KeychainToolReaderTests {
    final class Calls: @unchecked Sendable {
        let lock = NSLock(); var items: [(String, [String])] = []
        func add(_ e: String, _ a: [String]) { lock.withLock { items.append((e, a)) } }
    }

    // The default read goes through /usr/bin/security (stable identity across rebuilds: no keychain dialog).
    @Test func readsThroughTheSecurityTool() throws {
        let calls = Calls()
        let reader = KeychainToolReader(account: "dictate-user") { exe, args in
            calls.add(exe, args); return KeychainToolReader.Output(status: 0, stdout: "gsk_fixture\n")
        }
        #expect(try reader.read(service: "groq-api") == "gsk_fixture")
        #expect(calls.items.first?.0 == "/usr/bin/security")
        #expect(calls.items.first?.1 == ["find-generic-password", "-s", "groq-api", "-a", "dictate-user", "-w"])
    }

    @Test func failureOrEmptyIsMissingKey() {
        let failing = KeychainToolReader(account: "a") { _, _ in KeychainToolReader.Output(status: 44, stdout: "") }
        #expect(throws: TranscriptionError.self) { try failing.read(service: "groq-api") }
        let empty = KeychainToolReader(account: "a") { _, _ in KeychainToolReader.Output(status: 0, stdout: "  \n") }
        #expect(throws: TranscriptionError.self) { try empty.read(service: "groq-api") }
    }

    // A hung tool (e.g. waiting on a dialog) is killed; the read fails instead of blocking.
    @Test func runToolTimesOut() throws {
        let start = Date()
        let out = try KeychainToolReader.runTool("/bin/sleep", ["5"], timeout: 0.3)
        #expect(out.status != 0)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func keyStoreDefaultsToTheSecurityTool() {
        #expect(KeyStore.defaultReaderName == "security-tool")
        #expect(KeyStore().readerName == "security-tool")
        #expect(KeyStore(reader: { _ in "x" }).readerName == "custom")
    }
}

@Suite("KeyUnavailable")
struct KeyUnavailableTests {
    // A tool that times out (likely blocked on a dialog) is reported as prompt_suppressed.
    @Test func timedOutToolIsPromptSuppressed() async throws {
        let reader = KeychainToolReader(account: "a") { _, _ in KeychainToolReader.Output(status: -1, stdout: "") }
        #expect(throws: KeyReadError.promptSuppressed) { try reader.read(service: "groq-api") }
        let store = KeyStore(reader: { try reader.read(service: $0) })
        store.prefetch(services: ["groq-api"])
        for _ in 0..<200 where store.missing(for: "groq-api") == .pending { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(store.missing(for: "groq-api") == .denied)
        #expect(store.failureReason(for: "groq-api") == "prompt_suppressed")
    }
}
