import Foundation

public enum MPRemoteCommandHandlerStatus { case success, noSuchContent, noActionableNowPlayingItem, deviceNotFound, commandFailed }

public class MPRemoteCommandEvent {}
public final class MPChangePlaybackRateCommandEvent: MPRemoteCommandEvent {
    public var playbackRate: Float { 1 }
}

public class MPRemoteCommand {
    public var isEnabled = true
    @discardableResult public func addTarget(handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any { 0 }
}
public final class MPChangePlaybackRateCommand: MPRemoteCommand {
    public var supportedPlaybackRates: [NSNumber] = []
}
public final class MPFeedbackCommand: MPRemoteCommand {
    public var localizedTitle = ""
}

public final class MPRemoteCommandCenter {
    public static func shared() -> MPRemoteCommandCenter { MPRemoteCommandCenter() }
    public let playCommand = MPRemoteCommand()
    public let pauseCommand = MPRemoteCommand()
    public let togglePlayPauseCommand = MPRemoteCommand()
    public let nextTrackCommand = MPRemoteCommand()
    public let previousTrackCommand = MPRemoteCommand()
    public let changePlaybackRateCommand = MPChangePlaybackRateCommand()
    public let bookmarkCommand = MPFeedbackCommand()
    public let likeCommand = MPFeedbackCommand()
    public let dislikeCommand = MPFeedbackCommand()
}

public let MPMediaItemPropertyTitle = "title"
public let MPMediaItemPropertyAlbumTitle = "album"
public let MPMediaItemPropertyArtist = "artist"
public let MPMediaItemPropertyPlaybackDuration = "duration"
public let MPNowPlayingInfoPropertyElapsedPlaybackTime = "elapsed"
public let MPNowPlayingInfoPropertyPlaybackRate = "rate"
public let MPNowPlayingInfoPropertyDefaultPlaybackRate = "default"

public final class MPNowPlayingInfoCenter {
    public static func `default`() -> MPNowPlayingInfoCenter { MPNowPlayingInfoCenter() }
    public var nowPlayingInfo: [String: Any]?
}
