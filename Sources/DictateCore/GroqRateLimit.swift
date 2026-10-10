import Foundation

/// Counts from one Groq response, including failed and hedged requests.
public struct GroqRateLimit: Sendable, Equatable {
    public enum Endpoint: Sendable, Equatable { case stt, cleanup }
    public let limitRequests: Int?
    public let remainingRequests: Int?
    public let limitTokens: Int?
    public let remainingTokens: Int?
    /// Seconds until the request/token window resets (`x-ratelimit-reset-*`).
    public let resetRequests: TimeInterval?
    public let resetTokens: TimeInterval?
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
        resetRequests = Self.parseDuration(response.value(forHTTPHeaderField: "x-ratelimit-reset-requests"))
        resetTokens = Self.parseDuration(response.value(forHTTPHeaderField: "x-ratelimit-reset-tokens"))
        self.endpoint = endpoint
    }

    /// Groq durations such as "2m59.56s", "7.66s", "1h2m3s", "120ms"; anything else is nil.
    public static func parseDuration(_ text: String?) -> TimeInterval? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var total = 0.0, number = "", unit = "", sawPart = false
        func flush() -> Bool {
            guard let value = Double(number), !unit.isEmpty else { return false }
            switch unit {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            case "ms": total += value / 1000
            default: return false
            }
            number = ""; unit = ""; sawPart = true
            return true
        }
        for ch in text {
            if ch.isASCII, ch.isNumber || ch == "." {
                if !unit.isEmpty, !flush() { return nil }
                number.append(ch)
            } else if ch.isASCII, ch.isLetter, !number.isEmpty {
                unit.append(ch)
            } else { return nil }
        }
        guard flush(), sawPart, total.isFinite else { return nil }
        return total
    }
}
