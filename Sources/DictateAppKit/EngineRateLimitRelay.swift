import Foundation
import DictateCore

/// The transport can complete on any executor, including after a hedge has lost.
/// Only the main actor reads/writes the host callback.
final class EngineRateLimitRelay: @unchecked Sendable {
    @MainActor var callback: ((GroqRateLimit) -> Void)?
    private let store: GroqQuotaStore
    init(store: GroqQuotaStore) { self.store = store }
    func observe(_ limits: GroqRateLimit) {
        store.record(limits)   // thread-safe: any executor, before the main-actor hop
        DispatchQueue.main.async { [self] in callback?(limits) }
    }
}

/// Covers the existing opt-in batch shadow STT without changing DictateCore's
/// batch client API. Chunked STT reports responses at its own send boundary.
struct EngineGroqTransport: HTTPTransport {
    let transport: HTTPTransport
    let observer: @Sendable (GroqRateLimit) -> Void
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.send(request)
        observer(GroqRateLimit(response: response, endpoint: .stt))
        return (data, response)
    }
}
