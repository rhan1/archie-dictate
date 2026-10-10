import DictateCore

/// Hardware boundary used by the existing controller. Hosts use the production
/// defaults; headless tests substitute capture, STT, HTTP and insertion independently.
protocol EngineRecorder: CaptureEngine {
    var onLevel: ((Double) -> Void)? { get set }
    var onPCMChunk: (([Int16]) -> Void)? { get set }
    var onFirstBuffer: (() -> Void)? { get set }
    var onCaptureFailure: (() -> Void)? { get set }
    var stats: AudioRecorder.CaptureStats { get }
    func startAsync(device: MicChoice) async throws
    func rebuildAsync() async throws
    func resetCapture()
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
}
