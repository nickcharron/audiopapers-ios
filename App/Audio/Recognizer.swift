import AudiopapersKit
import AVFoundation
import Foundation
import Speech

/// Apple's speech recognizer, fed whatever SpeechInput gives it. Commands are in English, whatever
/// else the phone is set to.
@MainActor
final class AppleRecognizer: RecognitionEngine {
    private let recognizer: SFSpeechRecognizer?

    init() {
        let current = Locale.current
        let wanted = current.language.languageCode?.identifier == "en" ? current : Locale(identifier: "en-US")
        recognizer = SFSpeechRecognizer(locale: wanted) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    var isAvailable: Bool { recognizer?.isAvailable == true }
    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func start(
        onDevice: Bool,
        terms: [String],
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String?) -> Void,
        onFailure: @escaping (RecognitionFailure) -> Void
    ) -> RecognitionSession? {
        guard let recognizer else { return nil }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            DispatchQueue.main.async { onFailure(.permission) }
            return AppleRecognitionSession(request: SFSpeechAudioBufferRecognitionRequest())
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = true
        request.contextualStrings = terms
        request.taskHint = .dictation
        let session = AppleRecognitionSession(request: request)
        // Delivered on the recognizer's queue, which is the main one by default.
        session.task = recognizer.recognitionTask(with: request) { [weak session] result, error in
            guard let session, !session.isCancelled else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    session.markDone()
                    onFinal(text)
                } else {
                    onPartial(text)
                }
            } else if let error {
                session.markDone()
                onFailure(AppleRecognizer.failure(error as NSError))
            }
        }
        return session
    }

    /// These codes are undocumented, but they're what the framework reports.
    private nonisolated static func failure(_ error: NSError) -> RecognitionFailure {
        switch (error.domain, error.code) {
        case ("kAFAssistantErrorDomain", 1110), ("kAFAssistantErrorDomain", 203):
            return .noSpeech
        case ("kAFAssistantErrorDomain", 1700), ("kAFAssistantErrorDomain", 1101), ("kLSRErrorDomain", 201):
            return .languageMissing
        case (NSURLErrorDomain, _), ("kAFAssistantErrorDomain", 1107):
            return .network
        default:
            return .other("\(error.domain) \(error.code): \(error.localizedDescription)")
        }
    }
}

final class AppleRecognitionSession: RecognitionSession, @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(micSampleRate), channels: 1, interleaved: false)
    fileprivate var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var cancelled = false
    private var done = false

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    fileprivate var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || done
    }

    fileprivate func markDone() {
        lock.lock()
        done = true
        lock.unlock()
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() {
            channel[i] = Float(sample) / Float(Int16.max)
        }
        request.append(buffer)
    }

    func endAudio() {
        request.endAudio()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        task?.cancel()
    }
}

/// What the app has to ask permission for.
enum Permissions {
    static func micAllowed() -> Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Speech recognition is a separate permission on iOS. Both are asked for together, the first
    /// time either is needed.
    static func requestMicAndSpeech() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return mic && speech
    }
}

/// Albert's short sounds, played through the same engine as everything else, so they don't disturb
/// the narration's place in the player.
@MainActor
final class Earcons: EarconPlayer {
    private let hub: AudioHub

    init(hub: AudioHub) { self.hub = hub }

    func listening() { hub.playTone(hertz: [880], seconds: 0.12) }
    func done() { hub.playTone(hertz: [660, 880], seconds: 0.15) }
    func working() { hub.playTone(hertz: [520], seconds: 0.06) }
}
