import Foundation

public enum DictationState: Equatable, Sendable { case idle, recording, transcribing }
public enum DictationAction: Equatable, Sendable {
    case none, startRecording, finishRecording, cancelRecording
}

public struct DictationStateMachine: Sendable {
    public private(set) var state: DictationState

    public init() { state = .idle }

    public mutating func doubleTap() -> DictationAction {
        switch state {
        case .idle:
            state = .recording
            return .startRecording
        case .recording:
            return finishButton()
        case .transcribing:
            return .none
        }
    }

    /// v1.1 A2: while recording, ONE clean Left-Option tap finishes. A tap
    /// while idle (the first half of a double-tap) does nothing.
    public mutating func singleTap() -> DictationAction {
        state == .recording ? finishButton() : .none
    }

    /// Routes a detector signal: ⌥⌥ starts, a single ⌥ finishes.
    public mutating func handle(_ signal: TapSignal) -> DictationAction {
        switch signal {
        case .none: return .none
        case .tap: return singleTap()
        case .doubleTap: return doubleTap()
        }
    }

    public mutating func finishButton() -> DictationAction {
        guard state == .recording else { return .none }
        state = .transcribing
        return .finishRecording
    }

    public mutating func cancel() -> DictationAction {
        guard state != .idle else { return .none }
        state = .idle
        return .cancelRecording
    }

    public mutating func maxDurationReached() -> DictationAction { finishButton() }

    public mutating func transcriptionFinished() {
        if state == .transcribing { state = .idle }
    }
}

public enum DictationLimits { public static let maxDuration: TimeInterval = 300 }
