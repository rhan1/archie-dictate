import Foundation

/// 1.29.15 (Archie 62.8.8): an on-device transcriber a host may hand `GroqChunkedTranscriber` (Archie's
/// `archieLocalSTT`, default off). It answers each chunk first; an error, an empty answer or no answer within
/// `GroqChunkedTranscriber.localTimeoutMs` sends that chunk down the unchanged cloud path (Groq → Scribe).
public protocol LocalChunkSTT: Sendable {
    var modelID: String { get }
    /// 16 kHz mono PCM16 in, the transcript out.
    func transcribe(pcm16k: [Int16]) async throws -> String
}

public enum LocalSTTError: Error, Equatable { case unavailable, engine(String), exited }

/// The `archie-stt-local` helper (transcribe.cpp + Parakeet, Archie `tools/stt-local`): started on first use, model
/// kept loaded, requests answered in order. A crash or hang stays in the helper; callers time out and fall back.
/// Frames on stdin: UInt32 LE id, UInt32 LE sample count, PCM16 LE. Lines on stdout: `id\tOK\ttext` / `id\tERR\tcode`.
public final class LocalSTTProcess: LocalChunkSTT, @unchecked Sendable {
    public let modelID: String
    public let executable: URL
    public let model: URL
    private let lock = NSLock()
    private let writes = DispatchQueue(label: "dictate.local-stt.write")
    private var process: Process?
    private var input: FileHandle?
    private var nextID: UInt32 = 0
    private var waiting: [UInt32: CheckedContinuation<String, Error>] = [:]
    private var pending = Data()

    public init(executable: URL, model: URL, modelID: String = "parakeet-tdt-0.6b-v2") {
        (self.executable, self.model, self.modelID) = (executable, model, modelID)
    }

    /// Starts the helper (loads the model) ahead of the first chunk.
    public func prewarm() { lock.withLock { _ = try? startedLocked() } }

    public func transcribe(pcm16k: [Int16]) async throws -> String {
        let id = lock.withLock { nextID &+= 1; return nextID }
        var frame = Data(capacity: 8 + pcm16k.count * 2)
        for word in [id, UInt32(pcm16k.count)] { withUnsafeBytes(of: word.littleEndian) { frame.append(contentsOf: $0) } }
        pcm16k.withUnsafeBufferPointer { frame.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress)?
            .assumingMemoryBound(to: UInt8.self), count: $0.count * 2)) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let handle: FileHandle? = lock.withLock {
                    if Task.isCancelled { return nil }
                    guard let handle = try? startedLocked() else { return nil }
                    waiting[id] = continuation
                    return handle
                }
                guard let handle else {
                    continuation.resume(throwing: Task.isCancelled ? CancellationError() : LocalSTTError.unavailable)
                    return
                }
                writes.async { [self] in
                    do { try handle.write(contentsOf: frame) } catch { resolve(id, .failure(LocalSTTError.exited)) }
                }
            }
        } onCancel: { resolve(id, .failure(CancellationError())) }
    }

    private func resolve(_ id: UInt32, _ result: Result<String, Error>) {
        lock.withLock { waiting.removeValue(forKey: id) }?.resume(with: result)
    }

    private func startedLocked() throws -> FileHandle {
        if let input, process?.isRunning == true { return input }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        (child.executableURL, child.arguments) = (executable, [model.path])
        (child.standardInput, child.standardOutput, child.standardError) = (stdin, stdout, FileHandle.nullDevice)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData) }
        child.terminationHandler = { [weak self] ended in self?.exited(ended) }
        // A write to a helper that just died must fail with EPIPE, never kill the host with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        return stdin.fileHandleForWriting
    }

    private func received(_ data: Data) {
        let lines: [Substring] = lock.withLock {
            pending.append(data)
            guard let last = pending.lastIndex(of: 0x0A) else { return [] }
            let complete = String(decoding: pending[..<last], as: UTF8.self)
            pending.removeSubrange(...last)
            return complete.split(separator: "\n", omittingEmptySubsequences: true)
        }
        for line in lines {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2, let id = UInt32(fields[0]) else { continue }    // READY / FAIL lines
            let text = fields.count == 3 ? String(fields[2]) : ""
            resolve(id, fields[1] == "OK" ? .success(text) : .failure(LocalSTTError.engine(text)))
        }
    }

    private func exited(_ ended: Process) {
        let orphans: [CheckedContinuation<String, Error>] = lock.withLock {
            guard process === ended else { return [] }
            (process, input) = (nil, nil)
            pending.removeAll()
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        for continuation in orphans { continuation.resume(throwing: LocalSTTError.exited) }
    }
}
