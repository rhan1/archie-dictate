import DictateCore
import DictateAppKit

@MainActor final class ExampleHost {
    let engine: DictationEngine
    let hotkeys: OptionDoubleTapMonitor
    init() {
        engine = DictationEngine(keyStore: KeyStore(), paths: AppPaths(), surface: .none)
        hotkeys = OptionDoubleTapMonitor()
        engine.onState = { print($0) }
        engine.onTranscript = { text, timeline in print(text, timeline) }
        hotkeys.onDoubleTap = { [weak self] in self?.engine.start() }
        hotkeys.onTap = { [weak self] in self?.engine.tap() }
        hotkeys.onEscape = { [weak self] in self?.engine.escape() }
    }
    func enableHotkeys() -> Bool { hotkeys.start() }
    func stop() { hotkeys.stop(); engine.cancel() }
}

import Testing
import Foundation

@Suite("HostingExampleTests") @MainActor
struct HostingExampleTests {
    @Test func constructsHostWithoutStartingCaptureOrHotkeys() {
        let host = ExampleHost()
        #expect(host.engine.surface == .none)
        #expect(host.engine.mode == .dictate)
        #expect(host.engine.forceFallback == nil)
    }

    // A host can drive OutputMuter itself (own state file); constructing touches no device.
    @Test func systemOutputMuteIsPublic() {
        let device: OutputMuteDevice = SystemOutputMute()
        _ = OutputMuter(device: device, stateFile: FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-host-mute-\(UUID().uuidString)"))
    }

    // docs/HOSTING.md shows exactly the example compiled above.
    @Test func docExampleMatchesCompiledExample() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/HOSTING.md"), encoding: .utf8)
        let source = try String(contentsOf: here, encoding: .utf8)
        let block = doc.components(separatedBy: "```swift\n").dropFirst().first?.components(separatedBy: "```").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compiled = source.components(separatedBy: "\nimport Testing").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(block != nil && block == compiled)
    }
}
