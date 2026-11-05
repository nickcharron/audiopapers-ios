import Foundation

public typealias AVAudioFrameCount = UInt32
public typealias AVAudioFramePosition = Int64
public typealias AVAudioFormatSettings = [String: Any]

public enum AVAudioCommonFormat { case pcmFormatFloat32, pcmFormatInt16 }

public final class AVAudioFormat: NSObject, @unchecked Sendable {
    public init?(standardFormatWithSampleRate: Double, channels: UInt32) {}
    public init?(commonFormat: AVAudioCommonFormat, sampleRate: Double, channels: UInt32, interleaved: Bool) {}
    public var sampleRate: Double { 0 }
    public var channelCount: UInt32 { 0 }
    public var settings: [String: Any] { [:] }
    public var commonFormat: AVAudioCommonFormat { .pcmFormatFloat32 }
    public var isInterleaved: Bool { false }
}

public class AVAudioBuffer: @unchecked Sendable {}

public final class AVAudioPCMBuffer: AVAudioBuffer, @unchecked Sendable {
    public init?(pcmFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount) {}
    public var frameLength: AVAudioFrameCount = 0
    public var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 1, channels: 1)! }
    public var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { nil }
    public var int16ChannelData: UnsafePointer<UnsafeMutablePointer<Int16>>? { nil }
}

public final class AVAudioFile {
    public init(forReading: URL) throws {}
    public init(forWriting: URL, settings: [String: Any], commonFormat: AVAudioCommonFormat, interleaved: Bool) throws {}
    public var length: AVAudioFramePosition { 0 }
    public var processingFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 1, channels: 1)! }
    public func write(from: AVAudioPCMBuffer) throws {}
}

public final class AVAudioTime {}
public final class AVAudioPlayerTime { public var sampleTime: AVAudioFramePosition { 0 } }

public class AVAudioNode {
    public var lastRenderTime: AVAudioTime? { nil }
    public func outputFormat(forBus: Int) -> AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 1, channels: 1)! }
    public func installTap(onBus: Int, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {}
    public func removeTap(onBus: Int) {}
}

public typealias AVAudioNodeTapBlock = (AVAudioPCMBuffer, AVAudioTime) -> Void
public enum AVAudioPlayerNodeCompletionCallbackType { case dataConsumed, dataRendered, dataPlayedBack }
public typealias AVAudioPlayerNodeCompletionHandler = (AVAudioPlayerNodeCompletionCallbackType) -> Void
public struct AVAudioPlayerNodeBufferOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public final class AVAudioPlayerNode: AVAudioNode {
    public override init() {}
    public func play() {}
    public func pause() {}
    public func stop() {}
    public func playerTime(forNodeTime: AVAudioTime) -> AVAudioPlayerTime? { nil }
    public func scheduleSegment(_ file: AVAudioFile, startingFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount, at: AVAudioTime?, completionCallbackType: AVAudioPlayerNodeCompletionCallbackType, completionHandler: AVAudioPlayerNodeCompletionHandler?) {}
    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at: AVAudioTime?, options: AVAudioPlayerNodeBufferOptions, completionHandler: (() -> Void)?) {}
}

public final class AVAudioUnitTimePitch: AVAudioNode {
    public override init() {}
    public var rate: Float = 1
}

public final class AVAudioMixerNode: AVAudioNode {}
public final class AVAudioInputNode: AVAudioNode {
    public var isVoiceProcessingEnabled: Bool { false }
    public func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
}

public extension Notification.Name {
    static let AVAudioEngineConfigurationChange = Notification.Name("change")
}

public final class AVAudioEngine {
    public init() {}
    public var mainMixerNode: AVAudioMixerNode { AVAudioMixerNode() }
    public var inputNode: AVAudioInputNode { AVAudioInputNode() }
    public var isRunning: Bool { false }
    public func attach(_ node: AVAudioNode) {}
    public func detach(_ node: AVAudioNode) {}
    public func connect(_ from: AVAudioNode, to: AVAudioNode, format: AVAudioFormat?) {}
    public func disconnectNodeOutput(_ node: AVAudioNode) {}
    public func prepare() {}
    public func start() throws {}
    public func pause() {}
    public func stop() {}
}

public let AVAudioSessionInterruptionTypeKey = "type"
public let AVAudioSessionInterruptionOptionKey = "options"
public let AVAudioSessionRouteChangeReasonKey = "reason"

public final class AVAudioSession: @unchecked Sendable {
    public enum InterruptionType: UInt, Sendable { case began = 1, ended = 0 }
    public struct InterruptionOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let shouldResume = InterruptionOptions(rawValue: 1)
    }
    public enum RouteChangeReason: UInt, Sendable { case unknown = 0, newDeviceAvailable = 1, oldDeviceUnavailable = 2 }
    public struct Category: Sendable {
        public static let playback = Category()
        public static let playAndRecord = Category()
    }
    public struct Mode: Sendable {
        public static let `default` = Mode()
        public static let measurement = Mode()
        public static let spokenAudio = Mode()
    }
    public struct CategoryOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let allowBluetoothA2DP = CategoryOptions(rawValue: 1)
        public static let defaultToSpeaker = CategoryOptions(rawValue: 2)
    }
    public struct SetActiveOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }
    public static let interruptionNotification = Notification.Name("interruption")
    public static let routeChangeNotification = Notification.Name("route")
    public static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    public func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws {}
    public func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}
}

public final class AVAudioApplication: @unchecked Sendable {
    public enum recordPermission_ { case undetermined, denied, granted }
    public static let shared = AVAudioApplication()
    public var recordPermission: recordPermission_ { .granted }
    public static func requestRecordPermission() async -> Bool { true }
}

public final class AVAudioConverterStatusBox {}
public enum AVAudioConverterInputStatus { case haveData, noDataNow, endOfStream }
public enum AVAudioConverterOutputStatus { case haveData, inputRanDry, endOfStream, error }
public typealias AVAudioConverterInputBlock = (AVAudioPacketCount, UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?
public typealias AVAudioPacketCount = UInt32

public final class AVAudioConverter: @unchecked Sendable {
    public init?(from: AVAudioFormat, to: AVAudioFormat) {}
    public func convert(to: AVAudioBuffer, error: UnsafeMutablePointer<NSError?>?, withInputFrom: AVAudioConverterInputBlock) -> AVAudioConverterOutputStatus { .haveData }
}

public enum AVSpeechSynthesisVoiceQuality { case `default`, enhanced, premium }

public final class AVSpeechSynthesisVoice {
    public init?(identifier: String) {}
    public init?(language: String?) {}
    public static func speechVoices() -> [AVSpeechSynthesisVoice] { [] }
    public var language: String { "" }
    public var name: String { "" }
    public var identifier: String { "" }
    public var quality: AVSpeechSynthesisVoiceQuality { .default }
}

public final class AVSpeechUtterance {
    public init(string: String) {}
    public var voice: AVSpeechSynthesisVoice?
}

public final class AVSpeechSynthesizer: @unchecked Sendable {
    public init() {}
    public var usesApplicationAudioSession = true
    public func write(_ utterance: AVSpeechUtterance, toBufferCallback: @escaping (AVAudioBuffer) -> Void) {}
}

public protocol AVAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
}

public final class AVAudioPlayer {
    public init(contentsOf: URL) throws {}
    public weak var delegate: AVAudioPlayerDelegate?
    @discardableResult public func play() -> Bool { true }
    public func stop() {}
}
