import Foundation

/// What Dictate can ask of the system's media playback. Read-only queries plus
/// the play/pause media key — never volume or mute (Raza's standing rule).
public protocol MediaControl: AnyObject {
    /// Bundle ids of media apps currently producing audio, or nil when the
    /// playing state cannot be determined.
    func playingSources() -> Set<String>?
    /// Sends the system play/pause media key once.
    func togglePlayPause()
}

/// Pauses media while the user dictates and resumes it afterwards — only what
/// Dictate itself paused, and never a blind toggle (which would START playback).
public final class MediaPauser {
    public enum Event: String, Sendable { case paused, none, unknown, reverted, resumed, kept }

    /// Bundle-id prefixes of apps whose audio is media the play/pause key controls.
    public static let mediaApps = [
        "com.apple.Music", "com.spotify.client", "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit",
        "org.mozilla.firefox", "company.thebrowser", "com.microsoft.edgemac", "com.brave.Browser",
        "com.apple.TV", "com.apple.podcasts", "org.videolan.vlc", "com.colliderli.iina",
        "com.apple.QuickTimePlayerX", "com.tidal.desktop", "com.amazon.music", "com.apple.Books",
        "com.apple.mediaremote.nowplaying",
    ]

    private let control: MediaControl
    public private(set) var pausedByUs = false
    private var sourcesBeforePause: Set<String> = []

    public init(control: MediaControl) { self.control = control }

    public static func isMediaApp(_ bundleID: String) -> Bool {
        mediaApps.contains { bundleID.hasPrefix($0) }
    }

    /// Recording went live: pause media if (and only if) some is playing.
    public func pauseIfPlaying() -> Event {
        guard !pausedByUs else { return .paused }
        guard let sources = control.playingSources() else { return .unknown }
        let media = sources.filter(Self.isMediaApp)
        guard !media.isEmpty else { return .none }
        sourcesBeforePause = media
        control.togglePlayPause()
        pausedByUs = true
        return .paused
    }

    /// ~400 ms after pausing: a media app that was NOT playing before but is
    /// now means the key started something else — toggle it straight back.
    public func verifyAfterPause() -> Event? {
        guard pausedByUs, let sources = control.playingSources() else { return nil }
        let started = sources.filter(Self.isMediaApp).subtracting(sourcesBeforePause)
        guard !started.isEmpty else { return nil }
        control.togglePlayPause()
        pausedByUs = false
        return .reverted
    }

    /// Dictation ended (paste, cancel or error): resume only what we paused,
    /// and not if something is already playing again (the user resumed it).
    public func resumeIfWePaused() -> Event? {
        guard pausedByUs else { return nil }
        pausedByUs = false
        if let sources = control.playingSources(), !sources.filter(Self.isMediaApp).isEmpty { return .kept }
        control.togglePlayPause()
        return .resumed
    }
}
