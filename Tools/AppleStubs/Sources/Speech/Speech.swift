import AVFoundation
import Foundation

public enum SFSpeechRecognizerAuthorizationStatus { case notDetermined, denied, restricted, authorized }
public enum SFSpeechRecognitionTaskHint { case unspecified, dictation, search, confirmation }

public final class SFTranscription { public var formattedString: String { "" } }
public final class SFSpeechRecognitionResult {
    public var bestTranscription: SFTranscription { SFTranscription() }
    public var isFinal: Bool { false }
}
public final class SFSpeechRecognitionTask { public func cancel() {} }

public final class SFSpeechAudioBufferRecognitionRequest {
    public init() {}
    public var requiresOnDeviceRecognition = false
    public var shouldReportPartialResults = true
    public var contextualStrings: [String] = []
    public var taskHint = SFSpeechRecognitionTaskHint.unspecified
    public func append(_ buffer: AVAudioPCMBuffer) {}
    public func endAudio() {}
}

public final class SFSpeechRecognizer {
    public init?(locale: Locale) {}
    public var isAvailable: Bool { true }
    public var supportsOnDeviceRecognition: Bool { true }
    public static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus { .authorized }
    public static func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {}
    public func recognitionTask(with request: SFSpeechAudioBufferRecognitionRequest, resultHandler: @escaping (SFSpeechRecognitionResult?, Error?) -> Void) -> SFSpeechRecognitionTask { SFSpeechRecognitionTask() }
}
