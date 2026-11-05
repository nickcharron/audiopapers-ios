import AudiopapersKit
import Foundation
import MediaPlayer
import Observation

/// What the lock screen, Control Center, Bluetooth headsets and car head units see and control.
/// Each paragraph is loaded on its own, so the player never has a "next" or "previous" item of its
/// own: these commands go to the reading session instead, so a headset's or car's skip buttons move
/// through the paper. iOS has no custom lock-screen buttons, but its feedback commands (shown in the
/// lock screen's menu) can be named: they're Albert, and Describe and Skip while a figure prompt waits.
@MainActor
final class NowPlaying {
    private let hub: AudioHub
    private let engine: ReadingEngine
    private let voice: VoiceController

    init(hub: AudioHub, engine: ReadingEngine, voice: VoiceController) {
        self.hub = hub
        self.engine = engine
        self.voice = voice
        hub.onNowPlayingChanged = { [weak self] in self?.update() }
        configureCommands()
        followPrompts()
    }

    private func configureCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in self?.run { $0.engine.setPlaying(true) } ?? .noActionableNowPlayingItem }
        commands.pauseCommand.addTarget { [weak self] _ in self?.run { $0.engine.setPlaying(false) } ?? .noActionableNowPlayingItem }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.run { $0.engine.togglePlayPause() } ?? .noActionableNowPlayingItem }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.run { $0.engine.nextFromMediaButton() } ?? .noActionableNowPlayingItem }
        // Headphone/lock-screen "previous" mirrors "next": a paragraph at a time.
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.run { $0.engine.previousParagraph() } ?? .noActionableNowPlayingItem }
        commands.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        commands.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let rateEvent = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            return self?.run { $0.engine.setRate(rateEvent.playbackRate) } ?? .noActionableNowPlayingItem
        }
        commands.bookmarkCommand.localizedTitle = "Albert"
        commands.bookmarkCommand.addTarget { [weak self] _ in self?.run { $0.voice.pushToTalk() } ?? .noActionableNowPlayingItem }
        commands.likeCommand.localizedTitle = "Describe"
        commands.likeCommand.addTarget { [weak self] _ in self?.run { $0.engine.describeYes() } ?? .noActionableNowPlayingItem }
        commands.dislikeCommand.localizedTitle = "Skip"
        commands.dislikeCommand.addTarget { [weak self] _ in self?.run { $0.engine.describeNo() } ?? .noActionableNowPlayingItem }
        commands.likeCommand.isEnabled = false
        commands.dislikeCommand.isEnabled = false
    }

    private func run(_ action: (NowPlaying) -> Void) -> MPRemoteCommandHandlerStatus {
        action(self)
        return .success
    }

    /// Swaps Describe and Skip in while a describe prompt waits for an answer, and Albert in when
    /// the mic can be used from the lock screen.
    private func followPrompts() {
        withObservationTracking {
            let commands = MPRemoteCommandCenter.shared()
            let prompting = engine.uiState.session?.pendingPrompt != nil
            commands.likeCommand.isEnabled = prompting
            commands.dislikeCommand.isEnabled = prompting
            commands.bookmarkCommand.isEnabled = voice.handsFree
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followPrompts() }
            }
        }
    }

    private func update() {
        guard let item = hub.currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyAlbumTitle: "Audiopapers",
            MPMediaItemPropertyPlaybackDuration: Double(hub.durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(hub.currentPositionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: hub.isPlaying ? Double(hub.playbackRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let artist = item.artist { info[MPMediaItemPropertyArtist] = artist }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
