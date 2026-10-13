/// Capture intent before pausing; a second inactive event must not overwrite it.
struct VideoPlaybackResumeState {
    private var isSuspended = false
    private var shouldResume = false

    mutating func suspend(wasPlaying: Bool) {
        guard !isSuspended else { return }
        isSuspended = true
        shouldResume = wasPlaying
    }

    mutating func resume() -> Bool {
        guard isSuspended else { return false }
        isSuspended = false
        return shouldResume
    }
}
