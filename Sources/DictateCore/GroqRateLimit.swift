import Foundation

/// Counts from one Groq response, including failed and hedged requests.
public struct GroqRateLimit: Sendable, Equatable {
    public enum Endpoint: Sendable, Equatable { case stt, cleanup }
    public let limitRequests: Int?
    public let remainingRequests: Int?
    public let limitTokens: Int?
    public let remainingTokens: Int?
    public let endpoint: Endpoint

    public init(response: HTTPURLResponse, endpoint: Endpoint) {
        func count(_ name: String) -> Int? {
            guard let value = response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(value)
        }
        limitRequests = count("x-ratelimit-limit-requests")
        remainingRequests = count("x-ratelimit-remaining-requests")
        limitTokens = count("x-ratelimit-limit-tokens")
        remainingTokens = count("x-ratelimit-remaining-tokens")
        self.endpoint = endpoint
    }
}
