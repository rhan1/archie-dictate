import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

@Suite("HostMuteRecoveryTests") @MainActor
struct HostMuteRecoveryTests {
    private func paths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-host-mute-\(UUID().uuidString)")
        let paths = AppPaths(home: root)
        try FileManager.default.createDirectory(at: paths.mutedStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return paths
    }

    @Test func nothingPendingReturnsNil() throws {
        let engine = DictationEngine(keyStore: KeyStore(), paths: try paths(), surface: .none)
        #expect(engine.recoverStaleMute() == nil)
    }

    // An unreadable record fails before any device is touched.
    @Test func corruptRecordReportsRestoreFailed() throws {
        let paths = try paths()
        try "garbage".write(to: paths.mutedStateURL, atomically: true, encoding: .utf8)
        let engine = DictationEngine(keyStore: KeyStore(), paths: paths, surface: .none)
        #expect(engine.recoverStaleMute() == "restore_failed")
    }
}

@Suite("HostDiagnosticsTests", .serialized) @MainActor
struct HostDiagnosticsTests {
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ line: String) { lock.withLock { items.append(line) } }
        var all: [String] { lock.withLock { items } }
    }

    // Hosts get every stderr note (timeline, keys, bridge, media) through onDiagnostic.
    @Test func hostReceivesNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-host-diag-\(UUID().uuidString)")
        let paths = AppPaths(home: root)
        try FileManager.default.createDirectory(at: paths.mutedStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "garbage".write(to: paths.mutedStateURL, atomically: true, encoding: .utf8)
        let engine = DictationEngine(keyStore: KeyStore(), paths: paths, surface: .none)
        let lines = Lines()
        engine.onDiagnostic = { lines.add($0) }
        defer { engine.onDiagnostic = nil }
        engine.recoverStaleMute()
        #expect(lines.all.contains { $0.hasSuffix("dictate: media=restore_failed (host launch)") })
        engine.onDiagnostic = nil
        engine.recoverStaleMute()
        #expect(lines.all.count == 1)
    }
}
