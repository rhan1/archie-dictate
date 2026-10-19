/// Host-selected speech recognition lane. Existing callers retain Groq chunking.
public enum DictationSTT: String, Sendable {
    case groqChunked = "groq"
    case deepgramStreaming = "deepgram"

    /// What a host gets when it states no preference. Changing it never moves an explicit choice.
    public static let `default`: DictationSTT = .groqChunked
    /// The standalone app's preference key (`defaults write … DictationSTT deepgram`).
    public static let preferenceKey = "DictationSTT"
    /// Keychain service for the Deepgram key; the account is `NSUserName()` (KeychainToolReader's default,
    /// the same account Archie's `DictateKitAdapter.archieKeyStore()` reads).
    public static let deepgramKeyService = "deepgram-api"

    /// An explicit, valid preference value; nil for missing or invalid text.
    public static func explicit(_ raw: String?) -> DictationSTT? {
        guard let raw else { return nil }
        return DictationSTT(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Missing/invalid → `defaultValue` (Groq unless a caller passes another); an explicit value always wins.
    public static func resolve(_ raw: String?, default defaultValue: DictationSTT = .default) -> DictationSTT {
        explicit(raw) ?? defaultValue
    }
}
