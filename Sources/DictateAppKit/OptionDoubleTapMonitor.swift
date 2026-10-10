import DictateCore

/// Optional host-owned hotkeys. Detection remains the standalone app's detector.
@MainActor public final class OptionDoubleTapMonitor {
    public var onDoubleTap: (() -> Void)?
    public var onTap: (() -> Void)?
    public var onEscape: (() -> Void)?
    private let monitor = HotkeyMonitor()
    private var running = false

    public init() {
        monitor.onSignal = { [weak self] signal in
            switch signal {
            case .doubleTap: self?.onDoubleTap?()
            case .tap: self?.onTap?()
            case .none: break
            }
        }
        monitor.onEscape = { [weak self] in self?.onEscape?() }
    }
    @discardableResult public func start() -> Bool {
        if running { return true }
        running = monitor.start()
        return running
    }
    public func stop() { monitor.stop(); running = false }
    deinit { monitor.stop() }
}
