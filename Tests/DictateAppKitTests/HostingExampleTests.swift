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
        hotkeys.onTap = { [weak self] in self?.engine.finish() }
        hotkeys.onEscape = { [weak self] in self?.engine.escape() }
    }
    func enableHotkeys() -> Bool { hotkeys.start() }
    func stop() { hotkeys.stop(); engine.cancel() }
}

import Testing

@Suite("HostingExampleTests") @MainActor
struct HostingExampleTests {
    @Test func constructsHostWithoutStartingCaptureOrHotkeys() {
        let host = ExampleHost()
        #expect(host.engine.surface == .none)
        #expect(host.engine.mode == .dictate)
        #expect(host.engine.forceFallback == nil)
    }
}
