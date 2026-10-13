import Testing
@testable import Zeying

struct VideoPlaybackResumeStateTests {
    @Test("Manually paused video stays paused after an interruption")
    func manualPause() {
        var state = VideoPlaybackResumeState()
        state.suspend(wasPlaying: false)
        let resumed = state.resume()
        #expect(!resumed)
    }

    @Test("Background to inactive preserves playback intent")
    func repeatedInactive() {
        var state = VideoPlaybackResumeState()
        state.suspend(wasPlaying: true)
        state.suspend(wasPlaying: false)
        let resumed = state.resume()
        #expect(resumed)
        let repeatedResume = state.resume()
        #expect(!repeatedResume)
        state.suspend(wasPlaying: false)
        let pausedResume = state.resume()
        #expect(!pausedResume)
    }
}
