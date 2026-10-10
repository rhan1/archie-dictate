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
