import Foundation

/// Binary PCM and text control frames share one injected connection per dictation.
public protocol WebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String?
    /// Must unblock a pending receive. Safe to call more than once.
    func close()
}

public protocol WebSocketTransport: Sendable {
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection
}

public struct URLSessionWebSocketTransport: WebSocketTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration)
    }

    public func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        do {
            // Await the upgrade before reporting a successful connection.
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            } onCancel: {
                task.cancel(with: .goingAway, reason: nil)
            }
            return SessionWebSocketConnection(task: task)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }
}

private final class SessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }
    func send(_ data: Data) async throws { try await task.send(.data(data)) }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String? {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(data: data, encoding: .utf8) ?? ""
            @unknown default: return ""
            }
        } catch {
            if task.closeCode == .normalClosure { return nil }
            throw error
        }
    }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
}
