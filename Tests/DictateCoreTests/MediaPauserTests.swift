import Testing
import DictateCore

/// Fake media system: `playing` is what CoreAudio would report; a toggle flips
/// the "now playing" app between playing and paused.
final class FakeMedia: MediaControl {
    var playing: Set<String>? = []
    var nowPlayingApp = "com.spotify.client"
    var toggles = 0
    var startsOtherApp: String?

    func playingSources() -> Set<String>? { playing }
    func togglePlayPause() {
        toggles += 1
        if let other = startsOtherApp { playing?.insert(other); return }
        guard playing != nil else { return }
        if playing!.contains(nowPlayingApp) { playing!.remove(nowPlayingApp) } else { playing!.insert(nowPlayingApp) }
    }
}

@Suite("MediaPauser")
struct MediaPauserTests {
    @Test func pausesOnLiveAndResumesOnEnd() {
        let media = FakeMedia(); media.playing = ["com.spotify.client"]
        let p = MediaPauser(control: media)
        #expect(p.pauseIfPlaying() == .paused)
        #expect(media.playing == [])
        #expect(p.verifyAfterPause() == nil)
        #expect(p.resumeIfWePaused() == .resumed)
        #expect(media.playing == ["com.spotify.client"])
        #expect(media.toggles == 2)
    }

    @Test func nothingPlayingMeansNoToggleAndNoResume() {
        let media = FakeMedia()
        let p = MediaPauser(control: media)
        #expect(p.pauseIfPlaying() == .none)
        #expect(p.resumeIfWePaused() == nil)
        #expect(media.toggles == 0)
    }

    @Test func unknownStateNeverSendsABlindToggle() {
        let media = FakeMedia(); media.playing = nil
        let p = MediaPauser(control: media)
        #expect(p.pauseIfPlaying() == .unknown)
        #expect(p.resumeIfWePaused() == nil)
        #expect(media.toggles == 0)
    }

    @Test func nonMediaAudioIsLeftAlone() {
        let media = FakeMedia(); media.playing = ["us.zoom.xos", "com.tinyspeck.slackmacgap"]
        let p = MediaPauser(control: media)
        #expect(p.pauseIfPlaying() == .none)
        #expect(media.toggles == 0)
    }

    @Test func keyThatStartsAnotherAppIsReverted() {
        let media = FakeMedia(); media.playing = ["com.google.Chrome.helper"]; media.startsOtherApp = "com.apple.Music"
        let p = MediaPauser(control: media)
        #expect(p.pauseIfPlaying() == .paused)
        #expect(p.verifyAfterPause() == .reverted)
        #expect(media.toggles == 2)
        #expect(p.resumeIfWePaused() == nil)       // nothing of ours to resume
        #expect(media.toggles == 2)
    }

    @Test func userResumedDuringDictationIsKept() {
        let media = FakeMedia(); media.playing = ["com.spotify.client"]
        let p = MediaPauser(control: media)
        _ = p.pauseIfPlaying()
        media.playing = ["com.spotify.client"]    // user pressed play mid-dictation
        #expect(p.resumeIfWePaused() == .kept)
        #expect(media.toggles == 1)
    }

    @Test func chromeHelperCountsAsMedia() {
        #expect(MediaPauser.isMediaApp("com.google.Chrome.helper"))
        #expect(!MediaPauser.isMediaApp("us.zoom.xos"))
    }
}
