import AppKit

/// One gate for every panel operation, including levels and hide. With .none,
/// the real panel is never even constructed. Timers/outcomes live in the controller.
protocol EnginePanelDriving: AnyObject {
    var onCancel: (() -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
    var isOnScreen: Bool { get }
    var frame: NSRect { get }
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?)
    func hide()
    func push(level: Double)
}
extension PillPanel: EnginePanelDriving {}

final class EnginePanel {
    var surface: Surface {
        didSet { if surface == .none, oldValue == .pill { panel?.hide() } }
    }
    var onMode: ((PillPanel.Mode) -> Void)?
    var onCancel: (() -> Void)? { didSet { panel?.onCancel = onCancel } }
    var onFinish: (() -> Void)? { didSet { panel?.onFinish = onFinish } }
    private let factory: () -> EnginePanelDriving
    private var panel: EnginePanelDriving?
    init(surface: Surface, factory: @escaping () -> EnginePanelDriving = { PillPanel() }) {
        self.surface = surface; self.factory = factory
    }
    private func visiblePanel() -> EnginePanelDriving? {
        guard surface == .pill else { return nil }
        if panel == nil {
            panel = factory(); panel?.onCancel = onCancel; panel?.onFinish = onFinish
        }
        return panel
    }
    func show(_ mode: PillPanel.Mode, held: Bool = false, status: String? = nil) {
        onMode?(mode)
        visiblePanel()?.show(mode, held: held, status: status)
    }
    func hide() { onMode?(.hidden); if surface == .pill { panel?.hide() } }
    func push(level: Double) { visiblePanel()?.push(level: level) }
    var isOnScreen: Bool { surface == .pill && (panel?.isOnScreen ?? false) }
    var frame: NSRect { surface == .pill ? (panel?.frame ?? .zero) : .zero }
}
