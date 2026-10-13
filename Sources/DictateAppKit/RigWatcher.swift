import Foundation
import DictateCore

/// v1.14: what the rig's trigger asks the host to do — exactly its own ⌥ tap and ⌥⌥.
public enum RigGesture: Sendable, Equatable { case tap, doubleTap }

/// v1.14: polls the rig's 0600 trigger file (50 ms) and performs the operator's ⌥⌥ through the host's
/// own gesture path: a `.tap`, then `.doubleTap` 200 ms later (inside the 350 ms double-tap window),
/// as the hotkey monitor reports a real chord. Main thread only. Exists only when the launch environment enabled the rig.
final class RigWatcher {
    static let chordGap: TimeInterval = 0.2
    let config: RigConfig
    /// The row named by the latest chord: the session it starts or ends is that row's.
    private(set) var row: String?
    private let gesture: (RigGesture) -> Void
    private let note: (String) -> Void
    private var timer: Timer?

    init(config: RigConfig, note: @escaping (String) -> Void, gesture: @escaping (RigGesture) -> Void) {
        self.config = config
        self.note = note
        self.gesture = gesture
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// One look at the trigger file (tests call this directly). Returns what was read.
    @discardableResult func poll() -> RigTriggerReading {
        let reading = RigTriggerFile.consume(at: config.triggerURL)
        switch reading {
        case .none: break
        case .rejected(let reason): note("rig_trigger_rejected=\(reason)")
        case .chord(let row):
            self.row = row
            note("rig_trigger=chord row=\(row)")
            gesture(.tap)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.chordGap) { [weak self] in self?.gesture(.doubleTap) }
        }
        return reading
    }
}
