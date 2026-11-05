import AudiopapersKit
import AVFoundation
import Foundation

private let renderTimeoutNanoseconds: UInt64 = 120_000_000_000

/// The phone's own text-to-speech, written to a file rather than spoken, so it plays through the
/// same player as everything else. Offline and free.
final class PhoneVoice: PhoneSynthesizer, @unchecked Sendable {
    /// One render at a time, as AVSpeechSynthesizer's own queue would do anyway.
    private let lock = AsyncLock()

    func render(_ text: String, voiceIdentifier: String?, to url: URL) async throws {
        try await lock.withLock {
            try await self.write(text, voiceIdentifier: voiceIdentifier, to: url)
        }
    }

    private func write(_ text: String, voiceIdentifier: String?, to url: URL) async throws {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = false
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: "en-US")
        let job = RenderJob(url: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            job.start(continuation)
            synthesizer.write(utterance) { buffer in job.receive(buffer) }
            // A speech engine that never answers would otherwise leave someone listening to silence.
            Task {
                try? await Task.sleep(nanoseconds: renderTimeoutNanoseconds)
                job.finish(SpeechFailure("Text-to-speech failed"))
            }
        }
        withExtendedLifetime(synthesizer) {}
    }

    /// Offline voices in English, as (identifier, label). Unlike Android's, iOS's have names.
    static func englishVoices() -> [(identifier: String, label: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { voice in
                let accent = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
                let quality = voice.quality == .premium ? ", premium" : voice.quality == .enhanced ? ", enhanced" : ""
                return (voice.identifier, "\(voice.name) (\(accent)\(quality))")
            }
    }
}

/// One rendering's file, written as its audio arrives on the synthesizer's own thread.
private final class RenderJob: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: AVAudioFile?

    init(url: URL) { self.url = url }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        // An empty buffer is how it says it's finished.
        if pcm.frameLength == 0 {
            finish(wroteSomething ? nil : SpeechFailure("Text-to-speech failed"))
            return
        }
        do {
            lock.lock()
            defer { lock.unlock() }
            if continuation == nil { return }
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            finish(SpeechFailure("Text-to-speech failed"))
        }
    }

    private var wroteSomething: Bool {
        lock.lock()
        defer { lock.unlock() }
        return file != nil
    }

    func finish(_ error: Error? = nil) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        file = nil // closes it
        lock.unlock()
        if let error {
            waiting?.resume(throwing: error)
        } else {
            waiting?.resume()
        }
    }
}
