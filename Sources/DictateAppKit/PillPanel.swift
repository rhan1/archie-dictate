import AppKit

/// D4: the Wispr-style pill. A non-activating floating panel that never takes
/// focus from the app being dictated into.
public final class PillPanel {
    public enum Mode: Equatable { case hidden, recording, transcribing, error }

    public static let size = NSSize(width: 250, height: 52)
    public static let dockGap: CGFloat = 24

    public var onCancel: (() -> Void)? {
        get { pillView.onCancel }
        set { pillView.onCancel = newValue }
    }
    public var onFinish: (() -> Void)? {
        get { pillView.onFinish }
        set { pillView.onFinish = newValue }
    }
    public private(set) var mode: Mode = .hidden

    private let panel: NonActivatingPanel
    private let pillView: PillView
    private var animationTimer: Timer?
    private var errorHideWork: DispatchWorkItem?
    /// G2 RED lever: with DICTATE_PILL_HIDE=1 the pill is never put on screen.
    private let suppressed = ProcessInfo.processInfo.environment["DICTATE_PILL_HIDE"] == "1"

    public init() {
        pillView = PillView(frame: NSRect(origin: .zero, size: PillPanel.size))
        panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: PillPanel.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = pillView
    }

    public func push(level: Float) {
        pillView.push(level: CGFloat(level))
    }

    public func show(_ newMode: Mode) {
        errorHideWork?.cancel()
        mode = newMode
        pillView.mode = newMode
        guard newMode != .hidden else { return hide() }
        if newMode == .recording { pillView.resetLevels() }
        if !panel.isVisible && !suppressed {
            panel.setFrameOrigin(PillPanel.origin(for: PillPanel.size))
            panel.orderFrontRegardless()
        }
        startAnimating()
        if newMode == .error {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            errorHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    public func hide() {
        errorHideWork?.cancel()
        mode = .hidden
        pillView.mode = .hidden
        animationTimer?.invalidate()
        animationTimer = nil
        panel.orderOut(nil)
    }

    public var isOnScreen: Bool { panel.isVisible }
    public var frame: NSRect { panel.frame }

    /// Bottom-centre of the screen holding the mouse, 24 pt above the Dock edge
    /// (visibleFrame already excludes the Dock and the menu bar).
    public static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + dockGap)
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pillView.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }
}

final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PillView: NSView {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var mode: PillPanel.Mode = .hidden { didSet { needsDisplay = true } }

    private static let capsuleColor = NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0, alpha: 1)
    private static let cancelFill = NSColor(srgbRed: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0, alpha: 1)
    private static let barCount = 10
    private static let buttonDiameter: CGFloat = 36

    private var levels = [CGFloat](repeating: 0, count: PillView.barCount)
    private var displayed = [CGFloat](repeating: 0, count: PillView.barCount)
    private var phase: CGFloat = 0

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var cancelRect: NSRect {
        let d = PillView.buttonDiameter
        return NSRect(x: (bounds.height - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
    }
    var finishRect: NSRect {
        let d = PillView.buttonDiameter
        return NSRect(x: bounds.width - (bounds.height - d) / 2 - d, y: (bounds.height - d) / 2, width: d, height: d)
    }

    func resetLevels() {
        levels = [CGFloat](repeating: 0, count: PillView.barCount)
        displayed = levels
    }

    func push(level: CGFloat) {
        levels.removeFirst()
        levels.append(max(0, min(1, level)))
    }

    func tick() {
        phase += 1.0 / 30.0
        for i in displayed.indices {
            displayed[i] += (levels[i] - displayed[i]) * 0.45
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if cancelRect.insetBy(dx: -4, dy: -4).contains(p) {
            onCancel?()
        } else if finishRect.insetBy(dx: -4, dy: -4).contains(p), mode == .recording {
            onFinish?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        PillView.capsuleColor.setFill()
        capsule.fill()

        drawCancelButton()
        drawFinishButton()

        switch mode {
        case .recording: drawBars()
        case .transcribing: drawDots()
        case .error: drawErrorMark()
        case .hidden: break
        }
    }

    private func drawCancelButton() {
        PillView.cancelFill.setFill()
        NSBezierPath(ovalIn: cancelRect).fill()
        NSColor.white.setStroke()
        let c = NSPoint(x: cancelRect.midX, y: cancelRect.midY)
        let r: CGFloat = 5.5
        let x = NSBezierPath()
        x.lineWidth = 2
        x.lineCapStyle = .round
        x.move(to: NSPoint(x: c.x - r, y: c.y - r)); x.line(to: NSPoint(x: c.x + r, y: c.y + r))
        x.move(to: NSPoint(x: c.x - r, y: c.y + r)); x.line(to: NSPoint(x: c.x + r, y: c.y - r))
        x.stroke()
    }

    private func drawFinishButton() {
        NSColor.white.withAlphaComponent(mode == .recording ? 1 : 0.55).setFill()
        NSBezierPath(ovalIn: finishRect).fill()
        NSColor.black.setStroke()
        let c = NSPoint(x: finishRect.midX, y: finishRect.midY)
        let check = NSBezierPath()
        check.lineWidth = 2.4
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: NSPoint(x: c.x - 6.5, y: c.y + 0.5))
        check.line(to: NSPoint(x: c.x - 2, y: c.y - 4.5))
        check.line(to: NSPoint(x: c.x + 7, y: c.y + 5))
        check.stroke()
    }

    private func drawBars() {
        let barWidth: CGFloat = 3, gap: CGFloat = 4
        let total = CGFloat(PillView.barCount) * barWidth + CGFloat(PillView.barCount - 1) * gap
        var x = bounds.midX - total / 2
        NSColor.white.setFill()
        for i in 0..<PillView.barCount {
            // Idle bars still breathe a little so the pill reads as "listening".
            let idle = 0.08 + 0.04 * sin(phase * 4 + CGFloat(i) * 0.9)
            let h = 3 + 22 * max(displayed[i], idle)
            let rect = NSRect(x: x, y: bounds.midY - h / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }

    private func drawDots() {
        let d: CGFloat = 6, gap: CGFloat = 7
        var x = bounds.midX - (3 * d + 2 * gap) / 2
        for i in 0..<3 {
            let alpha = 0.3 + 0.7 * (0.5 + 0.5 * sin(phase * 6 - CGFloat(i) * 0.9))
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - d / 2, width: d, height: d)).fill()
            x += d + gap
        }
    }

    private func drawErrorMark() {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let r: CGFloat = 8
        NSColor.systemRed.setStroke()
        let x = NSBezierPath()
        x.lineWidth = 3
        x.lineCapStyle = .round
        x.move(to: NSPoint(x: c.x - r, y: c.y - r)); x.line(to: NSPoint(x: c.x + r, y: c.y + r))
        x.move(to: NSPoint(x: c.x - r, y: c.y + r)); x.line(to: NSPoint(x: c.x + r, y: c.y - r))
        x.stroke()
    }
}
