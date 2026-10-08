import AppKit

/// D4: the Wispr-style pill. A non-activating floating panel that never takes
/// focus from the app being dictated into.
public final class PillPanel {
    public enum Mode: Equatable { case hidden, warming, recording, transcribing, error }

    /// Measured from Wispr Flow's own pill on this Mac (2026-10-09 01:01, 2x
    /// capture ÷ 2): 102 × 30 pt including a 1 pt #20201F outline.
    public static let capsuleSize = NSSize(width: 102, height: 30)
    /// Transparent margin around the capsule so its soft shadow is not clipped.
    public static let shadowMargin: CGFloat = 6
    public static var size: NSSize {
        NSSize(width: capsuleSize.width + 2 * shadowMargin, height: capsuleSize.height + 2 * shadowMargin)
    }
    /// Wispr sits 14 pt above the bottom of the screen's usable area.
    public static let dockGap: CGFloat = 14

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
        guard !demoLevels else { return }
        pillView.push(level: CGFloat(level))
    }

    /// QA lever (DICTATE_DEMO_LEVELS=1): drive the bars with a synthetic voice
    /// level so the animation can be captured without anyone speaking.
    private let demoLevels = ProcessInfo.processInfo.environment["DICTATE_DEMO_LEVELS"] == "1"
    private var demoPhase: CGFloat = 0

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
            guard let self else { return }
            if self.demoLevels {
                self.demoPhase += 1.0 / 30.0
                self.pillView.push(level: 0.55 + 0.4 * sin(self.demoPhase * 5))
            }
            self.pillView.tick()
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
    private static let outlineColor = NSColor(srgbRed: 0x20 / 255.0, green: 0x20 / 255.0, blue: 0x1F / 255.0, alpha: 1)
    private static let cancelFill = NSColor(srgbRed: 0x3E / 255.0, green: 0x3B / 255.0, blue: 0x32 / 255.0, alpha: 1)
    private static let finishFill = NSColor(srgbRed: 0xFC / 255.0, green: 0xFC / 255.0, blue: 0xFA / 255.0, alpha: 1)
    static let outlineWidth: CGFloat = 1
    static let barCount = 10
    static let buttonDiameter: CGFloat = 18
    /// From the capsule's outer edge to the button (1 pt outline + 5 pt).
    static let buttonInset: CGFloat = 6
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 2
    static let barIdleHeight: CGFloat = 2
    static let barPeakHeight: CGFloat = 16
    /// Smoothing for the in-place bar motion (~50 ms attack, ~250 ms decay at 30 fps).
    static let attack: CGFloat = 0.48
    static let decay: CGFloat = 0.124

    /// Latest mic level and its smoothed value. Bars never scroll: each one
    /// scales about its own centre from this single level times a slow per-bar
    /// variation, so the pill "breathes" like Wispr's instead of sweeping.
    private var target: CGFloat = 0
    private(set) var smoothed: CGFloat = 0
    private var phase: CGFloat = 0
    private let barSpeed: [CGFloat] = (0..<PillView.barCount).map { 2.1 + CGFloat(($0 * 7) % 5) * 0.37 }
    private let barOffset: [CGFloat] = (0..<PillView.barCount).map { CGFloat(($0 * 3) % 7) * 0.9 }

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
        target = 0
        smoothed = 0
    }

    func push(level: CGFloat) {
        target = max(0, min(1, level))
    }

    func tick() {
        phase += 1.0 / 30.0
        smoothed += (target - smoothed) * (target > smoothed ? PillView.attack : PillView.decay)
        needsDisplay = true
    }

    /// Height of bar `i` right now (x never changes; only this does).
    func barHeight(_ i: Int) -> CGFloat {
        let variation = 0.55 + 0.45 * (0.5 + 0.5 * sin(phase * barSpeed[i] + barOffset[i]))
        let centre = 1 - abs(CGFloat(i) - CGFloat(PillView.barCount - 1) / 2) / CGFloat(PillView.barCount) * 0.6
        return PillView.barIdleHeight + (PillView.barPeakHeight - PillView.barIdleHeight) * smoothed * variation * centre
    }

    /// x of bar `i` — fixed, centred between the two buttons.
    func barX(_ i: Int) -> CGFloat {
        let total = CGFloat(PillView.barCount) * PillView.barWidth + CGFloat(PillView.barCount - 1) * PillView.barGap
        let start = ((cancelRect.maxX + finishRect.minX) / 2 - total / 2).rounded()
        return start + CGFloat(i) * (PillView.barWidth + PillView.barGap)
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
        let inner = c.insetBy(dx: PillView.outlineWidth, dy: PillView.outlineWidth)
        let fill = NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        PillView.outlineColor.setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        PillView.capsuleColor.setFill()
        fill.fill()

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
        PillView.finishFill.withAlphaComponent(mode == .recording ? 1 : 0.55).setFill()
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
        let barWidth = PillView.barWidth
        (live ? NSColor.white : NSColor(white: 0.45, alpha: 1)).setFill()
        for i in 0..<PillView.barCount {
            // Quiet = 2 pt dots, like Wispr; voice scales each bar in place.
            let h = live ? barHeight(i) : PillView.barIdleHeight
            let rect = NSRect(x: barX(i), y: capsuleRect.midY - h / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
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
