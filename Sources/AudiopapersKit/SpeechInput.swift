import Foundation

private let frameMs: Int64 = 80
private let finishWaitMs: Int64 = 6_000
private let failuresToGiveUp = 3
private let maxCapturedSamples = micSampleRate * 30

/// What's being listened for, which sets how long to wait for it.
public enum ListenMode: String, Sendable {
    // Short, since waiting this long is what a false "Hey Albert" costs: narration is paused.
    case command
    case followUp = "follow_up"
    case yesNo = "yes_no"
    case question
    case dictation

    var times: ListenTimes { Core.catalog.listenModes[rawValue]! }
}

public enum RecognitionFailure: Equatable, Sendable {
    case noSpeech
    case permission
    case network
    /// The recognizer hasn't got the language yet. That's no fault of the way it was asked, and it
    /// may be fixed by fetching the language, so it doesn't count against that way of hearing.
    case languageMissing
    case other(String)
}

/// One go at recognizing speech, fed audio as it comes.
public protocol RecognitionSession: AnyObject {
    func append(_ samples: [Int16])
    func endAudio()
    func cancel()
}

/// The platform's speech recognizer. Callbacks arrive on the main thread.
@MainActor
public protocol RecognitionEngine: AnyObject {
    var isAvailable: Bool { get }
    var supportsOnDevice: Bool { get }
    func start(
        onDevice: Bool,
        terms: [String],
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String?) -> Void,
        onFailure: @escaping (RecognitionFailure) -> Void
    ) -> RecognitionSession?
}

/// Speech to text from anywhere in the app. What ReadingEngine and VoiceController see of SpeechInput.
@MainActor
public protocol SpeechListening: AnyObject {
    var isAvailable: Bool { get }

    /// Listens once. `onText` gets what was heard, or nil if nothing was; `onFailure` a message for
    /// anything else. `onSayAgain` means speech was heard but lost, so it's worth asking for it
    /// again. `fromWake` means the wake phrase fired just now, so a little of what came before this
    /// call belongs to it. `terms` are words worth favouring, such as the paper's headings.
    func listen(
        mode: ListenMode,
        terms: [String],
        fromWake: Bool,
        onPartial: @escaping (String) -> Void,
        onText: @escaping (String?) -> Void,
        onFailure: @escaping (String) -> Void,
        onSayAgain: @escaping () -> Void
    )

    /// Stops listening early; what was heard so far still arrives.
    func stop()

    /// Stops listening and drops whatever was heard.
    func cancel()
}

/// Speech to text with the phone's own recognizer. Its audio always comes through MicPipeline, so
/// the rolling buffer means nothing is lost after "Hey Albert", and the mic never changes hands.
/// The recognizer on this phone is preferred to a server, so commands work without a signal; a way
/// of hearing that keeps failing is given up on (and remembered, until "Hey Albert" is next turned
/// on in Settings). A failed way of hearing hands on what it was given to the next, so nothing said
/// is lost by that either.
@MainActor
public final class SpeechInput: SpeechListening {
    private enum Route: String, CaseIterable {
        case device = "DEVICE"
        case server = "SERVER"
    }

    private final class Listen: @unchecked Sendable {
        let mode: ListenMode
        let terms: [String]
        let fromWake: Bool
        let onPartial: (String) -> Void
        let onText: (String?) -> Void
        let onFailure: (String) -> Void
        let onSayAgain: () -> Void
        var route = Route.server
        var triedRoutes = Set<Route>()
        var session: RecognitionSession?
        var endpointer: SpeechEndpointer?
        let capturedLock = NSLock()
        var captured: [Int16] = []
        var streaming = false
        var usedPipeline: MicPipeline?
        var ownsPipeline = false
        var languageMissing = false
        var timeout: Task<Void, Never>?
        var finishTimeout: Task<Void, Never>?

        init(mode: ListenMode, terms: [String], fromWake: Bool, onPartial: @escaping (String) -> Void, onText: @escaping (String?) -> Void, onFailure: @escaping (String) -> Void, onSayAgain: @escaping () -> Void) {
            self.mode = mode
            self.terms = terms
            self.fromWake = fromWake
            self.onPartial = onPartial
            self.onText = onText
            self.onFailure = onFailure
            self.onSayAgain = onSayAgain
        }
    }

    private let engine: RecognitionEngine
    /// One that isn't listening for the wake word, for hearing a command with nothing running.
    private let makePipeline: () -> MicPipeline
    /// The pipeline already listening for "Hey Albert", if there is one.
    public var pipeline: MicPipeline?
    private var active: Listen?
    private var softFailures: [Route: Int] = [:]

    public init(engine: RecognitionEngine, makePipeline: @escaping () -> MicPipeline) {
        self.engine = engine
        self.makePipeline = makePipeline
    }

    public var isAvailable: Bool { engine.isAvailable }

    /// Forgets which ways of hearing have failed, to try them all again.
    public func forgetFailures() {
        softFailures.removeAll()
        Settings.brokenSpeechRoutes = []
    }

    public func listen(
        mode: ListenMode,
        terms: [String],
        fromWake: Bool,
        onPartial: @escaping (String) -> Void,
        onText: @escaping (String?) -> Void,
        onFailure: @escaping (String) -> Void,
        onSayAgain: @escaping () -> Void
    ) {
        if let active { abandon(active) }
        let listen = Listen(mode: mode, terms: terms, fromWake: fromWake, onPartial: onPartial, onText: onText, onFailure: onFailure, onSayAgain: onSayAgain)
        active = listen
        guard let route = chooseRoute(listen) else {
            active = nil
            onFailure("Speech recognition isn't available on this phone.")
            return
        }
        begin(listen, route)
    }

    public func stop() {
        guard let listen = active else { return }
        listen.timeout?.cancel()
        stopFeeding(listen)
        listen.session?.endAudio()
        listen.finishTimeout?.cancel()
        listen.finishTimeout = after(finishWaitMs) { [weak self] in
            if self?.active === listen { self?.recognitionFailed(listen) }
        }
    }

    public func cancel() {
        if let active { abandon(active) }
    }

    private func abandon(_ listen: Listen) {
        listen.session?.cancel()
        finish(listen)
    }

    private func after(_ milliseconds: Int64, _ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await sleepMs(milliseconds)
                work()
            } catch {}
        }
    }

    private func availableRoutes() -> [Route] {
        Route.allCases.filter { route in
            route == .device ? engine.supportsOnDevice : engine.isAvailable
        }
    }

    private func chooseRoute(_ listen: Listen) -> Route? {
        let available = availableRoutes().filter { !listen.triedRoutes.contains($0) }
        let broken = Settings.brokenSpeechRoutes
        return available.first { !broken.contains($0.rawValue) } ?? available.first
    }

    private func begin(_ listen: Listen, _ route: Route) {
        listen.route = route
        listen.triedRoutes.insert(route)
        listen.session = nil
        let session = engine.start(
            onDevice: route == .device,
            terms: listen.terms,
            onPartial: { [weak self, weak listen] text in
                guard let self, let listen, self.active === listen, listen.route == route else { return }
                self.handlePartial(listen, text)
            },
            onFinal: { [weak self, weak listen] text in
                guard let self, let listen, self.active === listen, listen.route == route else { return }
                self.handleFinal(listen, text)
            },
            onFailure: { [weak self, weak listen] failure in
                guard let self, let listen, self.active === listen, listen.route == route else { return }
                self.handleFailure(listen, failure)
            }
        )
        guard let session else {
            recognitionFailed(listen)
            return
        }
        listen.session = session
        listen.capturedLock.lock()
        let replay = listen.captured
        listen.capturedLock.unlock()
        if !replay.isEmpty {
            session.append(replay)
            session.endAudio()
        } else {
            let pipeline = pipelineFor(listen)
            let times = listen.mode.times
            let endpointer = SpeechEndpointer(
                noSpeechFrames: Int(times.noSpeechMs / frameMs),
                endSilenceFrames: Int(times.endSilenceMs / frameMs),
                maxFrames: Int(times.maxMs / frameMs),
                initialNoiseFloorDb: pipeline.quietLevelDb()
            )
            listen.endpointer = endpointer
            listen.streaming = true
            listen.usedPipeline = pipeline
            pipeline.startStreaming(fromWake: listen.fromWake) { [weak self] frame in
                self?.onMicFrame(listen, session, endpointer, frame)
            }
        }
        listen.timeout?.cancel()
        listen.timeout = after(listen.mode.times.maxMs) { [weak self] in
            if self?.active === listen { self?.stop() }
        }
        Log.d("Listening with \(route.rawValue)")
    }

    private func pipelineFor(_ listen: Listen) -> MicPipeline {
        if let pipeline, pipeline.isRunning { return pipeline }
        let own = makePipeline()
        own.start()
        listen.ownsPipeline = true
        return own
    }

    /// On the mic's queue.
    private nonisolated func onMicFrame(_ listen: Listen, _ session: RecognitionSession, _ endpointer: SpeechEndpointer, _ frame: [Int16]) {
        session.append(frame)
        listen.capturedLock.lock()
        if listen.captured.count < maxCapturedSamples { listen.captured.append(contentsOf: frame) }
        listen.capturedLock.unlock()
        // A pre-roll arrives as one long array, which isn't a frame's worth of loudness.
        if frame.count != micFrameSamples { return }
        switch endpointer.feed(frame) {
        case .speechEnded, .tooLong:
            Task { @MainActor [weak self] in if self?.active === listen { self?.stop() } }
        case .noSpeech:
            Task { @MainActor [weak self] in if self?.active === listen { self?.nothingSaid(listen) } }
        default:
            break
        }
    }

    private func nothingSaid(_ listen: Listen) {
        abandon(listen)
        listen.onText(nil)
    }

    private func stopFeeding(_ listen: Listen) {
        if listen.streaming {
            listen.streaming = false
            listen.usedPipeline?.stopStreaming()
        }
    }

    private func finish(_ listen: Listen) {
        listen.timeout?.cancel()
        listen.finishTimeout?.cancel()
        stopFeeding(listen)
        if listen.ownsPipeline {
            listen.usedPipeline?.stop()
            listen.ownsPipeline = false
        }
        listen.usedPipeline = nil
        listen.session = nil
        if active === listen { active = nil }
    }

    private func delivered(_ listen: Listen) {
        softFailures[listen.route] = nil
        finish(listen)
    }

    private func heardSpeech(_ listen: Listen) -> Bool { listen.endpointer?.heardSpeech == true }

    /// The recognizer got nowhere, which can be bad luck rather than this way of hearing being
    /// broken, so it takes a few in a row to give up on it. On to the next way of hearing.
    private func recognitionFailed(_ listen: Listen, counts: Bool = true) {
        let route = listen.route
        if counts {
            let failures = (softFailures[route] ?? 0) + 1
            softFailures[route] = failures
            if failures >= failuresToGiveUp {
                Log.w("Giving up on hearing with \(route.rawValue)")
                Settings.brokenSpeechRoutes.insert(route.rawValue)
            }
        }
        listen.session?.cancel()
        listen.session = nil
        stopFeeding(listen)
        if let next = chooseRoute(listen) {
            begin(listen, next)
        } else if listen.languageMissing {
            finish(listen)
            listen.onFailure(
                "This phone's speech recognition doesn't have English yet. Turn on Dictation in Settings, General, Keyboard, " +
                    "which fetches it."
            )
        } else if heardSpeech(listen) {
            finish(listen)
            listen.onSayAgain()
        } else {
            finish(listen)
            listen.onText(nil)
        }
    }

    private func handlePartial(_ listen: Listen, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { listen.onPartial(trimmed) }
    }

    private func handleFinal(_ listen: Listen, _ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed ?? "").isEmpty && heardSpeech(listen) {
            recognitionFailed(listen)
            return
        }
        delivered(listen)
        listen.onText(trimmed)
    }

    private func handleFailure(_ listen: Listen, _ failure: RecognitionFailure) {
        switch failure {
        case .noSpeech:
            if heardSpeech(listen) {
                recognitionFailed(listen)
            } else {
                finish(listen)
                listen.onText(nil)
            }
        case .permission:
            finish(listen)
            listen.onFailure("Microphone and speech recognition permission are needed for that.")
        case .network:
            if chooseRoute(listen) != nil {
                recognitionFailed(listen)
            } else {
                finish(listen)
                listen.onFailure("Speech recognition needs a connection on this phone.")
            }
        case .languageMissing:
            Log.w("Speech recognition has no language with \(listen.route.rawValue)")
            listen.languageMissing = true
            recognitionFailed(listen, counts: false)
        case .other(let description):
            Log.w("Speech recognition error with \(listen.route.rawValue): \(description)")
            recognitionFailed(listen)
        }
    }
}
