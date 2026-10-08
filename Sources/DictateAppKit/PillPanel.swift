import AppKit

/// D4: the Wispr-style pill. A non-activating floating panel that never takes
/// focus from the app being dictated into.
public final class PillPanel {
    public enum Mode: Equatable { case hidden, warming, recording, transcribing, error }

    /// Measured from Wispr Flow's own pill (2x capture ÷ 2): 100 × 28 pt.
    public static let capsuleSize = NSSize(width: 100, height: 28)
    /// Transparent margin around the capsule so its soft shadow is not clipped.
    public static let shadowMargin: CGFloat = 6
    public static var size: NSSize {
        NSSize(width: capsuleSize.width + 2 * shadowMargin, height: capsuleSize.height + 2 * shadowMargin)
    }
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
        if newMode == .recording || newMode == .warming { pillView.resetLevels() }
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

    /// Bottom-centre of the screen holding the mouse, the CAPSULE 24 pt above the
    /// Dock edge (visibleFrame already excludes the Dock and the menu bar).
    public static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + dockGap - shadowMargin)
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

    private static let capsuleColor = NSColor.black
    private static let cancelFill = NSColor(srgbRed: 0x3E / 255.0, green: 0x3B / 255.0, blue: 0x32 / 255.0, alpha: 1)
    static let barCount = 8
    static let buttonDiameter: CGFloat = 18
    static let buttonInset: CGFloat = 5
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 2
    static let barIdleHeight: CGFloat = 2.5
    static let barPeakHeight: CGFloat = 14

    private var levels = [CGFloat](repeating: 0, count: PillView.barCount)
    private var displayed = [CGFloat](repeating: 0, count: PillView.barCount)
    private var phase: CGFloat = 0

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var capsuleRect: NSRect {
        bounds.insetBy(dx: PillPanel.shadowMargin, dy: PillPanel.shadowMargin)
    }
    var cancelRect: NSRect {
        let d = PillView.buttonDiameter, c = capsuleRect
        return NSRect(x: c.minX + PillView.buttonInset, y: c.midY - d / 2, width: d, height: d)
    }
    var finishRect: NSRect {
        let d = PillView.buttonDiameter, c = capsuleRect
        return NSRect(x: c.maxX - PillView.buttonInset - d, y: c.midY - d / 2, width: d, height: d)
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
        if cancelRect.insetBy(dx: -3, dy: -3).contains(p) {
            onCancel?()
        } else if finishRect.insetBy(dx: -3, dy: -3).contains(p), mode == .recording || mode == .warming {
            onFinish?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let c = capsuleRect
        let capsule = NSBezierPath(roundedRect: c, xRadius: c.height / 2, yRadius: c.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        PillView.capsuleColor.setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()

        drawCancelButton()
        drawFinishButton()

        switch mode {
        case .warming: drawBars(live: false)
        case .recording: drawBars(live: true)
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
        let r: CGFloat = 3.25
        let x = NSBezierPath()
        x.lineWidth = 1.5
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
        check.lineWidth = 1.5
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.move(to: NSPoint(x: c.x - 3.75, y: c.y + 0.25))
        check.line(to: NSPoint(x: c.x - 1.25, y: c.y - 2.5))
        check.line(to: NSPoint(x: c.x + 4, y: c.y + 2.75))
        check.stroke()
    }

    /// `live: false` = WARMING: grey, flat, still — the mic is not delivering
    /// audio yet (Bluetooth profile switch).
    private func drawBars(live: Bool) {
        let barWidth = PillView.barWidth, gap = PillView.barGap
        let total = CGFloat(PillView.barCount) * barWidth + CGFloat(PillView.barCount - 1) * gap
        // Centred between the two buttons.
        var x = ((cancelRect.maxX + finishRect.minX) / 2 - total / 2).rounded()
        (live ? NSColor.white : NSColor(white: 0.45, alpha: 1)).setFill()
        for i in 0..<PillView.barCount {
            // Quiet = flat 2.5 pt dashes, like Wispr; voice lifts them toward 14 pt.
            let level = live ? displayed[i] : 0
            let h = PillView.barIdleHeight + (PillView.barPeakHeight - PillView.barIdleHeight) * level
            let rect = NSRect(x: x, y: capsuleRect.midY - h / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }

    private func drawDots() {
        let d: CGFloat = 3, gap: CGFloat = 4
        var x = capsuleRect.midX - (3 * d + 2 * gap) / 2
        for i in 0..<3 {
            let alpha = 0.3 + 0.7 * (0.5 + 0.5 * sin(phase * 6 - CGFloat(i) * 0.9))
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - d / 2, width: d, height: d)).fill()
            x += d + gap
        }
    }

    private func drawErrorMark() {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let r: CGFloat = 4
        NSColor.systemRed.setStroke()
        let x = NSBezierPath()
        x.lineWidth = 2
        x.lineCapStyle = .round
        x.move(to: NSPoint(x: c.x - r, y: c.y - r)); x.line(to: NSPoint(x: c.x + r, y: c.y + r))
        x.move(to: NSPoint(x: c.x - r, y: c.y + r)); x.line(to: NSPoint(x: c.x + r, y: c.y - r))
        x.stroke()
    }
}
