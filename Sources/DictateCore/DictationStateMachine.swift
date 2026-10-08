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
