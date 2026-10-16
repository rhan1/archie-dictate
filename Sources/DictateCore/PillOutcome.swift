/// Pure presentation and one-shot recovery for a completed dictation.
public struct PillOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case held(String), error(String), rawPasted(String), ok
    }
    public enum Event: Equatable, Sendable {
        case dismissTap, escape, recoverTap, singleOptionTap, tick(elapsed: Double)
    }
    public struct Output: Equatable, Sendable {
        public var label: String?
        public var pasteHeldText: Bool
    }
    public let kind: Kind
    public let hasText: Bool
    public private(set) var isVisible: Bool
    public var isRecoverable: Bool {
        guard isVisible else { return false }
        switch kind { case .held, .error: return true; default: return false }
    }
    public var showsPasteAffordance: Bool { isRecoverable && hasText }
    public var label: String? {
        guard isVisible else { return nil }
        switch kind {
        case .held(let reason):
            if reason == "paste_timeout" { return "paste unconfirmed · ⌘V to paste" }
            return reason == "no_stt" ? "no speech" : "held"
        case .error(let reason):
            let reason = reason.lowercased()
            if reason.contains("mic_dead") { return "no mic signal" }
            if reason.contains("mic_start") || reason.contains("mic_denied") { return "no mic" }
            if reason.contains("missing_key") { return "no key" }
            if reason.contains("timedout") { return "timeout" }
            if reason.contains("cannotconnecttohost") || reason.contains("notconnected") || reason.contains("not connected") || reason.contains("-1004") || reason.contains("-1009") { return "offline" }
            if reason == "silence" { return "no speech" }
            return "error"
        case .rawPasted: return "raw"
        case .ok: return nil
        }
    }
    public init(_ kind: Kind, hasText: Bool = false) {
        self.kind = kind
        self.hasText = hasText
        isVisible = kind != .ok
    }
    @discardableResult
    public mutating func handle(_ event: Event) -> Output {
        var paste = false
        if isVisible {
            switch event {
            case .dismissTap, .escape: isVisible = false
            case .recoverTap, .singleOptionTap:
                if isRecoverable, hasText { paste = true; isVisible = false }
            case .tick(let elapsed):
                let deadline: Double
                switch kind { case .rawPasted: deadline = 1.5; default: deadline = 20 }
                if elapsed >= deadline { isVisible = false }
            }
        }
        return Output(label: label, pasteHeldText: paste)
    }
}
