import Foundation
import DictateCore

/// Hardware boundary used by the existing controller. Hosts use the production
/// defaults; headless tests substitute capture, STT, HTTP and insertion independently.
protocol EngineRecorder: CaptureEngine {
    var onLevel: ((Double) -> Void)? { get set }
    var onPCMChunk: (([Int16]) -> Void)? { get set }
    var onFirstBuffer: (() -> Void)? { get set }
    var onCaptureFailure: ((CaptureFailure) -> Void)? { get set }
    var stats: AudioRecorder.CaptureStats { get }
    func startAsync(device: MicChoice) async throws
    func rebuildAsync() async throws
    func resetCapture()
    var bridgeHasAudio: Bool { get }
}
extension AudioRecorder: EngineRecorder {}

struct EngineDependencies {
    var recorder: EngineRecorder
    var makeApple: () -> EngineAppleSession
    var sttTransport: HTTPTransport
    var groqCleanupTransport: HTTPTransport
    var localCleanupTransport: HTTPTransport
    var inserter: TextInserter
    var panelFactory: () -> EnginePanelDriving
    var requestMicrophoneAccess: (@escaping (Bool) -> Void) -> Void
    var frontmostTarget: () -> InsertionTarget?
    var manageMedia: Bool
    /// v1.19 (ST1): the streaming provider's socket, its clock (deadlines), and a test observer of
    /// every final segment the session hands the pipeline.
    var wsTransport: any WebSocketTransport = URLSessionWebSocketTransport()
    var streamingClock: any DictateClock = SystemClock()
    var onStreamingSegment: (@Sendable (Int, String) -> Void)? = nil
    /// v1.19 (ST2): the learner's focused-element reader and its delay scheduler (nil reader = no focus).
    var focusSnapshot: (() -> FocusSnapshot?)? = nil
    var learnerSchedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil
}
