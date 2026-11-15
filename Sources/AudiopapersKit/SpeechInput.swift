import Foundation

private let frameMs: Int64 = 80
private let finishWaitMs: Int64 = 6_000
private let failuresToGiveUp = 3
private let maxCapturedSamples = micSampleRate * 30
// A question or note waiting on its "over" (see listen's untilOver) ends anyway after this much
// quiet, so forgetting to say it never leaves the mic open.
private let overBackstopMs: Int64 = 20_000
private let overMaxMs: Int64 = 180_000
// The pause after "over" that finishes it: shorter than a command's, since "over" already says so.
private let overPauseMs: Int64 = 800

/// What's being listened for, which sets how long to wait for it.
public enum ListenMode: String, Sendable {
    // Short, since waiting this long is what a false "Hey Albert" costs: narration is paused.
    case command
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
    ///
    /// Normally a pause ends it. With `untilOver` it carries on through pauses until the last thing
    /// said is "over", which is left out of what arrives, or until it's been quiet for a while. With
    /// `onPause`, each pause is passed what's been said so far, until the caller answers with
    /// `keepUntilOver` or `stop`; listening carries on meanwhile.
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
    )

    /// What's being said is a question or a note, as the caller decided at a pause: it carries on
    /// through pauses from now on, until the last thing said is "over".
    func keepUntilOver()

    /// Stops listening early; what was heard so far still arrives.
    func stop()

    /// Stops listening and drops whatever was heard.
    func cancel()
}

extension SpeechListening {
    /// Listens once, until the first pause.
    public func listen(
        mode: ListenMode,
        terms: [String],
        fromWake: Bool,
        onPartial: @escaping (String) -> Void,
        onText: @escaping (String?) -> Void,
        onFailure: @escaping (String) -> Void,
        onSayAgain: @escaping () -> Void
    ) {
        listen(
            mode: mode, terms: terms, fromWake: fromWake, untilOver: false, onPause: nil,
            onPartial: onPartial, onText: onText, onFailure: onFailure, onSayAgain: onSayAgain
        )
    }
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

    /// What a pause in the speech does: ends it, asks the caller (who answers with `keepUntilOver`
    /// or `stop`), or ends it only if the last thing said was "over".
    private enum Pauses { case end, ask, over }

    private final class Listen: @unchecked Sendable {
        let mode: ListenMode
        let terms: [String]
        let fromWake: Bool
        let onPause: ((String) -> Void)?
        let onPartial: (String) -> Void
        let onText: (String?) -> Void
        let onFailure: (String) -> Void
        let onSayAgain: () -> Void
        var pauses: Pauses
        var route = Route.server
        var triedRoutes = Set<Route>()
        // The session and endpointer are swapped on the main thread while the mic's queue uses
        // them, so both are only touched under capturedLock.
        private(set) var session: RecognitionSession?
        private(set) var endpointer: SpeechEndpointer?
        let capturedLock = NSLock()
        var captured: [Int16] = []
        var streaming = false
        var streamedBefore = false
        var usedPipeline: MicPipeline?
        var ownsPipeline = false
        var languageMissing = false
        var timeout: Task<Void, Never>?
        var finishTimeout: Task<Void, Never>?
        var backstop: Task<Void, Never>?
        /// Which recognizer session the callbacks that count are from.
        var token = 0
        // Listening through pauses can take several recognizer sessions: what the earlier ones
        // made out, and what the one going now has so far.
        var heard = ""
        var partial = ""
        var sessionOpen = false
        var paused = false
        var finishing = false
        let startedAt = Date()

        init(
            mode: ListenMode, terms: [String], fromWake: Bool, pauses: Pauses, onPause: ((String) -> Void)?,
            onPartial: @escaping (String) -> Void, onText: @escaping (String?) -> Void,
            onFailure: @escaping (String) -> Void, onSayAgain: @escaping () -> Void
        ) {
            self.mode = mode
            self.terms = terms
            self.fromWake = fromWake
            self.pauses = pauses
            self.onPause = onPause
            self.onPartial = onPartial
            self.onText = onText
            self.onFailure = onFailure
            self.onSayAgain = onSayAgain
        }

        func soFar() -> String { Over.join(heard, partial) }

        func feed(session: RecognitionSession?, endpointer: SpeechEndpointer?) {
            capturedLock.lock()
            self.session = session
            self.endpointer = endpointer
            capturedLock.unlock()
        }

        func feed(endpointer: SpeechEndpointer?) { feed(session: session, endpointer: endpointer) }

        func resetCaptured() {
            capturedLock.lock()
            captured = []
            capturedLock.unlock()
        }
    }

    private let engine: RecognitionEngine
    /// One that isn't listening for the wake word, for hearing a command with nothing running.
    private let makePipeline: () -> MicPipeline
    /// The pipeline already listening for "Hey Albert", if there is one.
    public var pipeline: MicPipeline?
    private var active: Listen?
    private var softFailures: [Route: Int] = [:]
    private var lastToken = 0

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
        untilOver: Bool,
        onPause: ((String) -> Void)?,
        onPartial: @escaping (String) -> Void,
        onText: @escaping (String?) -> Void,
        onFailure: @escaping (String) -> Void,
        onSayAgain: @escaping () -> Void
    ) {
        if let active { abandon(active) }
        let pauses: Pauses = untilOver ? .over : (onPause != nil ? .ask : .end)
        let listen = Listen(
            mode: mode, terms: terms, fromWake: fromWake, pauses: pauses, onPause: onPause,
            onPartial: onPartial, onText: onText, onFailure: onFailure, onSayAgain: onSayAgain
        )
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
        listen.finishing = true
        listen.timeout?.cancel()
        listen.backstop?.cancel()
        // Between stretches of speech, with nothing said since the last one: nothing to wait for.
        let nothingNew = !listen.heard.isEmpty && listen.partial.isEmpty && !heardSpeech(listen)
        if !listen.sessionOpen || nothingNew {
            if listen.sessionOpen {
                listen.token = 0
                listen.session?.cancel()
            }
            deliver(listen)
            return
        }
        stopFeeding(listen)
        listen.session?.endAudio()
        listen.finishTimeout?.cancel()
        listen.finishTimeout = after(finishWaitMs) { [weak self] in
            guard let self, self.active === listen else { return }
            if listen.heard.isEmpty {
                self.recognitionFailed(listen)
            } else {
                listen.token = 0
                listen.session?.cancel()
                self.deliver(listen)
            }
        }
    }

    public func keepUntilOver() {
        guard let listen = active, listen.pauses != .over, !listen.finishing else { return }
        listen.pauses = .over
        listen.timeout?.cancel()
        listen.timeout = after(maxMs(listen)) { [weak self] in
            if self?.active === listen { self?.stop() }
        }
        guard listen.paused else { return }
        if Over.endsWith(listen.soFar()) {
            stop()
        } else {
            armBackstop(listen, overBackstopMs)
            if listen.sessionOpen { listen.feed(endpointer: freshEndpointer(listen)) }
        }
    }

    public func cancel() {
        if let active { abandon(active) }
    }

    private func abandon(_ listen: Listen) {
        listen.token = 0
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
        listen.capturedLock.lock()
        let replay = listen.captured
        listen.capturedLock.unlock()
        guard startSession(listen, replay: replay) else {
            recognitionFailed(listen)
            return
        }
        listen.timeout?.cancel()
        listen.timeout = after(maxMs(listen)) { [weak self] in
            if self?.active === listen { self?.stop() }
        }
        Log.d("Listening with \(route.rawValue)")
    }

    /// A recognizer session for what's being said, on the listen's route: given `replay` (what a
    /// failed one was given) and nothing more, or fed live from the mic.
    private func startSession(_ listen: Listen, replay: [Int16]) -> Bool {
        lastToken += 1
        let token = lastToken
        listen.token = token
        listen.feed(session: nil, endpointer: listen.endpointer)
        let session = engine.start(
            onDevice: listen.route == .device,
            terms: listen.terms,
            onPartial: { [weak self, weak listen] text in
                guard let self, let listen, self.active === listen, listen.token == token else { return }
                self.handlePartial(listen, text)
            },
            onFinal: { [weak self, weak listen] text in
                guard let self, let listen, self.active === listen, listen.token == token else { return }
                self.handleFinal(listen, text)
            },
            onFailure: { [weak self, weak listen] failure in
                guard let self, let listen, self.active === listen, listen.token == token else { return }
                self.handleFailure(listen, failure)
            }
        )
        guard let session else { return false }
        listen.sessionOpen = true
        if !replay.isEmpty {
            listen.feed(session: session, endpointer: listen.endpointer)
            session.append(replay)
            session.endAudio()
            return true
        }
        let pipeline = listen.usedPipeline ?? pipelineFor(listen)
        // Once something's been said, a pause is all the next endpointer is for: the backstop sees
        // to waiting for more.
        let saidSomething = listen.endpointer?.heardSpeech == true || !listen.heard.isEmpty
        let endpointer: SpeechEndpointer
        if saidSomething {
            endpointer = freshEndpointer(listen)
        } else {
            let times = listen.mode.times
            endpointer = SpeechEndpointer(
                noSpeechFrames: Int(times.noSpeechMs / frameMs),
                endSilenceFrames: Int(endSilenceMs(listen) / frameMs),
                maxFrames: Int((listen.pauses == .end ? times.maxMs : overMaxMs) / frameMs),
                initialNoiseFloorDb: pipeline.quietLevelDb()
            )
        }
        listen.feed(session: session, endpointer: endpointer)
        if !listen.streaming {
            listen.streaming = true
            listen.usedPipeline = pipeline
            let fromWake = listen.fromWake && !listen.streamedBefore
            listen.streamedBefore = true
            pipeline.startStreaming(fromWake: fromWake) { [weak self] frame in
                self?.onMicFrame(listen, frame)
            }
        }
        return true
    }

    /// Listening through pauses runs longer, counted from when it started.
    private func maxMs(_ listen: Listen) -> Int64 {
        guard listen.pauses == .over else { return listen.mode.times.maxMs }
        return max(1_000, overMaxMs - Int64(Date().timeIntervalSince(listen.startedAt) * 1000))
    }

    private func endSilenceMs(_ listen: Listen) -> Int64 {
        listen.pauses == .over ? overPauseMs : listen.mode.times.endSilenceMs
    }

    /// For the next pause: it never gives up waiting for speech, which the backstop sees to.
    private func freshEndpointer(_ listen: Listen) -> SpeechEndpointer {
        SpeechEndpointer(
            noSpeechFrames: .max,
            endSilenceFrames: Int(endSilenceMs(listen) / frameMs),
            maxFrames: .max,
            initialNoiseFloorDb: listen.endpointer?.floorDb ?? .nan
        )
    }

    private func pipelineFor(_ listen: Listen) -> MicPipeline {
        if let pipeline, pipeline.isRunning { return pipeline }
        let own = makePipeline()
        own.start()
        listen.ownsPipeline = true
        return own
    }

    /// On the mic's queue.
    private nonisolated func onMicFrame(_ listen: Listen, _ frame: [Int16]) {
        listen.capturedLock.lock()
        let session = listen.session
        let endpointer = listen.endpointer
        if listen.captured.count < maxCapturedSamples { listen.captured.append(contentsOf: frame) }
        // A pre-roll arrives as one long array, which isn't a frame's worth of loudness.
        let event = frame.count == micFrameSamples ? endpointer?.feed(frame) : nil
        listen.capturedLock.unlock()
        session?.append(frame)
        switch event {
        case .speechStarted?:
            Task { @MainActor [weak self] in if self?.active === listen { self?.resumed(listen) } }
        case .speechEnded?:
            Task { @MainActor [weak self] in
                guard let self, self.active === listen, listen.endpointer === endpointer else { return }
                self.paused(listen, sessionEnded: false)
            }
        case .tooLong?:
            Task { @MainActor [weak self] in if self?.active === listen { self?.stop() } }
        case .noSpeech?:
            Task { @MainActor [weak self] in if self?.active === listen { self?.nothingSaid(listen) } }
        default:
            break
        }
    }

    /// A pause in what's being said: the recognizer finished a stretch of it (`sessionEnded`), or
    /// the endpointer heard enough quiet.
    private func paused(_ listen: Listen, sessionEnded: Bool) {
        let soFar = listen.soFar()
        switch listen.pauses {
        case .end:
            if sessionEnded { deliver(listen) } else { stop() }
        case .over where Over.endsWith(soFar):
            if sessionEnded { deliver(listen) } else { stop() }
        case .over:
            carryOn(listen, sessionEnded: sessionEnded, backstopMs: overBackstopMs)
        case .ask:
            carryOn(listen, sessionEnded: sessionEnded, backstopMs: listen.mode.times.noSpeechMs)
            listen.onPause?(soFar)
        }
    }

    /// Keeps listening after a pause. Quiet for `backstopMs` from now, if given, finishes it.
    private func carryOn(_ listen: Listen, sessionEnded: Bool, backstopMs: Int64?) {
        if let backstopMs {
            listen.paused = true
            armBackstop(listen, backstopMs)
        }
        guard sessionEnded else {
            listen.feed(endpointer: freshEndpointer(listen))
            return
        }
        listen.resetCaptured()
        Task { @MainActor [weak self] in
            guard let self, self.active === listen, !listen.finishing else { return }
            if !self.startSession(listen, replay: []) { self.deliver(listen) }
        }
    }

    private func armBackstop(_ listen: Listen, _ milliseconds: Int64) {
        listen.backstop?.cancel()
        listen.backstop = after(milliseconds) { [weak self] in
            guard let self, self.active === listen, listen.pauses != .end else { return }
            self.stop()
        }
    }

    private func resumed(_ listen: Listen) {
        listen.paused = false
        listen.backstop?.cancel()
    }

    private func deliver(_ listen: Listen) {
        let soFar = listen.soFar()
        let text = listen.pauses == .over ? Over.strip(soFar) : soFar
        delivered(listen)
        listen.onText(text.isEmpty ? nil : text)
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
        listen.backstop?.cancel()
        stopFeeding(listen)
        if listen.ownsPipeline {
            listen.usedPipeline?.stop()
            listen.ownsPipeline = false
        }
        listen.usedPipeline = nil
        listen.feed(session: nil, endpointer: listen.endpointer)
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
        listen.token = 0
        listen.session?.cancel()
        listen.feed(session: nil, endpointer: listen.endpointer)
        listen.sessionOpen = false
        stopFeeding(listen)
        if let next = chooseRoute(listen) {
            begin(listen, next)
        } else if listen.languageMissing {
            finish(listen)
            listen.onFailure(
                "This phone's speech recognition doesn't have English yet. Turn on Dictation in Settings, General, Keyboard, " +
                    "which fetches it."
            )
        } else if !listen.heard.isEmpty {
            deliver(listen) // what was heard before this stretch
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
        guard !trimmed.isEmpty else { return }
        if trimmed != listen.partial {
            // After a long pause the recognizer can start its words again from nothing, as if what
            // came before was another session's.
            let previous = listen.partial
            let startedAgain = listen.pauses != .end && trimmed.count * 2 < previous.count
                && !previous.lowercased().hasPrefix(trimmed.lowercased())
            if startedAgain { listen.heard = Over.join(listen.heard, previous) }
            listen.partial = trimmed
            // Words can arrive a little after the pause that followed them, "over" included.
            if listen.paused && listen.pauses == .over && Over.endsWith(listen.soFar()) {
                listen.onPartial(listen.soFar())
                stop()
                return
            }
        }
        listen.onPartial(listen.soFar())
    }

    private func handleFinal(_ listen: Listen, _ text: String?) {
        listen.sessionOpen = false
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty && heardSpeech(listen) {
            recognitionFailed(listen)
            return
        }
        listen.heard = Over.join(listen.heard, trimmed)
        listen.partial = ""
        if listen.finishing || listen.pauses == .end {
            deliver(listen)
        } else {
            paused(listen, sessionEnded: true)
        }
    }

    private func handleFailure(_ listen: Listen, _ failure: RecognitionFailure) {
        listen.sessionOpen = false
        switch failure {
        case .noSpeech:
            if heardSpeech(listen) {
                recognitionFailed(listen)
            } else if !listen.heard.isEmpty || (listen.pauses != .end && !listen.partial.isEmpty) {
                // Nothing in this stretch, after something in an earlier one: still waiting for
                // more, unless that's all.
                listen.heard = listen.soFar()
                listen.partial = ""
                if listen.finishing || listen.pauses == .end {
                    deliver(listen)
                } else {
                    carryOn(listen, sessionEnded: true, backstopMs: nil)
                }
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
