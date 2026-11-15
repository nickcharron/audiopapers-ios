import Foundation
@testable import AudiopapersKit

/// Plays nothing: a test says when each item has "finished".
@MainActor
final class FakePlayer: PlayerBackend {
    var playWhenReady = true
    private(set) var isPlaying = false
    private(set) var state = PlayerState.idle
    private(set) var items: [PlayerItem] = []
    private(set) var currentIndex = 0
    var currentPositionMs: Int64 = 0
    var durationMs: Int64 = 10_000
    private(set) var rate: Float = 1
    private(set) var titles: [String] = []
    /// Every item started, by its media id, in order.
    private(set) var started: [String] = []

    var onIsPlayingChanged: ((Bool) -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?

    var itemCount: Int { items.count }
    var currentId: String? { items.indices.contains(currentIndex) ? items[currentIndex].mediaId : nil }

    func setItems(_ items: [PlayerItem], index: Int, positionMs: Int64) {
        self.items = items
        currentIndex = index
        currentPositionMs = positionMs
        state = .ready
        if let id = currentId { started.append(id) }
        titles.append(items.first?.title ?? "")
        setPlaying(playWhenReady)
    }

    func addItem(_ item: PlayerItem) { items.append(item) }

    func seek(index: Int, positionMs: Int64) {
        currentIndex = index
        currentPositionMs = positionMs
        state = .ready
    }

    func play() {
        playWhenReady = true
        setPlaying(!items.isEmpty && state != .ended)
    }

    func pause() {
        playWhenReady = false
        setPlaying(false)
    }

    func stop() {
        items = []
        currentIndex = 0
        state = .idle
        setPlaying(false)
    }

    func setRate(_ rate: Float) { self.rate = rate }
    func setCurrentTitle(_ title: String) { titles.append(title) }

    private func setPlaying(_ playing: Bool) {
        if playing != isPlaying {
            isPlaying = playing
            onIsPlayingChanged?(playing)
        }
    }

    /// The current file has played to its end.
    func finishItem() {
        if currentIndex + 1 < items.count {
            currentIndex += 1
        } else {
            state = .ended
            setPlaying(false)
            onEnded?()
        }
    }
}

final class FakePhoneVoice: PhoneSynthesizer, @unchecked Sendable {
    var failing = false
    private(set) var rendered: [String] = []
    private(set) var picked: [String?] = []

    func render(_ text: String, voiceIdentifier: String?, to url: URL) async throws {
        if failing { throw SpeechFailure("Text-to-speech failed") }
        rendered.append(text)
        picked.append(voiceIdentifier)
        try Data("audio".utf8).write(to: url)
    }
}

final class FakeKokoro: KokoroSynthesizer, @unchecked Sendable {
    private(set) var rendered: [String] = []

    func synthesize(_ text: String, voice: KokoroVoice, to url: URL) async throws {
        rendered.append(text)
        try Wav.write([Float](repeating: 0.1, count: 100), sampleRate: 24_000, to: url)
    }

    func release() async {}
}

/// Says whatever a test tells it was heard.
@MainActor
final class FakeListener: SpeechListening {
    var isAvailable = true
    private(set) var listens: [ListenMode] = []
    private(set) var cancelled = 0
    private(set) var stopped = 0
    private(set) var keptUntilOver = 0
    private var onText: ((String?) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var onSayAgain: (() -> Void)?
    private var onPartial: ((String) -> Void)?

    var isListening: Bool { onText != nil }

    func listen(
        mode: ListenMode,
        terms: [String],
        fromWake: Bool,
        untilOver: Bool,
        onPause: ((String) -> Void)?,
        onPartial: @escaping (String) -> Void,
        onText: @escaping (String?) -> Void,
        onFailure: @escaping (String) -> Void,
        onSayAgain: @escaping () -> Void
    ) {
        listens.append(mode)
        self.onPartial = onPartial
        self.onText = onText
        self.onFailure = onFailure
        self.onSayAgain = onSayAgain
    }

    func stop() { stopped += 1 }

    func keepUntilOver() { keptUntilOver += 1 }

    func cancel() {
        cancelled += 1
        onText = nil
    }

    func hear(_ text: String?) {
        let callback = onText
        onText = nil
        callback?(text)
    }

    func fail(_ problem: String) {
        let callback = onFailure
        onText = nil
        callback?(problem)
    }
}

final class FakeNotifier: Notifier, @unchecked Sendable {
    private(set) var sent: [(key: String, title: String, text: String)] = []
    func finished(key: String, title: String, text: String) { sent.append((key, title, text)) }
}

final class FakeLease: BackgroundLease {
    private(set) var ended: Bool?
    private(set) var progress: [(Int, Int)] = []
    func update(done: Int, total: Int) { progress.append((done, total)) }
    func end(success: Bool) { ended = success }
}

@MainActor
final class FakeRunner: BackgroundRunner {
    private(set) var leases: [FakeLease] = []
    private(set) var expiries: [@MainActor () -> Void] = []
    func begin(title: String, onExpire: @escaping @MainActor () -> Void) -> BackgroundLease {
        let lease = FakeLease()
        leases.append(lease)
        expiries.append(onExpire)
        return lease
    }
}

@MainActor
final class FakeEarcons: EarconPlayer {
    private(set) var played: [String] = []
    func listening() { played.append("listening") }
    func done() { played.append("done") }
    func working() { played.append("working") }
    func stillListening() { played.append("stillListening") }
}

/// Audio delivered when a test says so.
final class FakeMic: MicSource, @unchecked Sendable {
    private(set) var startedModes: [MicMode] = []
    private(set) var stops = 0
    private(set) var onSamples: (([Int16]) -> Void)?
    var failing = false

    func start(mode: MicMode, onSamples: @escaping ([Int16]) -> Void) throws {
        if failing { throw SpeechFailure("No microphone") }
        startedModes.append(mode)
        self.onSamples = onSamples
    }

    func stop() {
        stops += 1
        onSamples = nil
    }

    func deliver(_ samples: [Int16]) { onSamples?(samples) }
}

final class FakeRecognitionSession: RecognitionSession, @unchecked Sendable {
    private(set) var audio: [Int16] = []
    private(set) var ended = false
    private(set) var cancelled = false
    func append(_ samples: [Int16]) { audio.append(contentsOf: samples) }
    func endAudio() { ended = true }
    func cancel() { cancelled = true }
}

@MainActor
final class FakeRecognizer: RecognitionEngine {
    var isAvailable = true
    var supportsOnDevice = true
    private(set) var sessions: [FakeRecognitionSession] = []
    private(set) var onDevice: [Bool] = []
    private(set) var terms: [[String]] = []
    private(set) var onPartial: ((String) -> Void)?
    private(set) var onFinal: ((String?) -> Void)?
    private(set) var onFailure: ((RecognitionFailure) -> Void)?

    func start(
        onDevice: Bool,
        terms: [String],
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String?) -> Void,
        onFailure: @escaping (RecognitionFailure) -> Void
    ) -> RecognitionSession? {
        self.onDevice.append(onDevice)
        self.terms.append(terms)
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onFailure = onFailure
        let session = FakeRecognitionSession()
        sessions.append(session)
        return session
    }
}

final class FakeDetector: WakeDetector {
    var scores: [Float] = []
    func score(_ frame: [Int16]) throws -> Float { scores.isEmpty ? 0 : scores.removeFirst() }
    func reset() {}
}

/// Waits for something to become true while the main actor gets on with it.
@MainActor
func eventually(timeout: TimeInterval = 5, _ what: String = "condition", _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw SpeechFailure("Timed out waiting for \(what)") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Lets everything that's already ready to run go first.
@MainActor
func settled() async throws {
    try await Task.sleep(nanoseconds: 100_000_000)
}
