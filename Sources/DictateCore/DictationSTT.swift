/// Host-selected speech recognition lane. Existing callers retain Groq chunking.
public enum DictationSTT: String, Sendable {
    case groqChunked = "groq"
    case deepgramStreaming = "deepgram"
}
