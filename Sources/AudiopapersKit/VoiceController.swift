import Foundation
import Observation

// A paper left paused this long has probably been forgotten about, so the mic goes off rather than
// listening all night. It comes back when the app is next on screen.
private let idleStopMs: Int64 = 30 * 60 * 1000
private let workingSoundEveryMs: Int64 = 4_000
// "Hey Albert" followed by nothing but these, then a pause, is still on its way to something.
private let filler: Set<String> = ["um", "uh", "er", "erm", "hmm", "so", "okay", "ok", "well", "and", "alright", "actually", "like", "hey", "albert"]
private let questionDoneHint = "Say \"over\" when you're done asking your question."
private let noteDoneHint = "Say \"over\" when you're done with your note."

/// What Albert is up to, for the screens to show.
public enum VoiceState: Equatable, Sendable {
    /// Not listening for "Hey Albert" (though the Albert button still works).
    case off
    /// Listening for "Hey Albert".
    case waiting
    /// Taking in what's being said; `words` is what the recognizer has made out so far.
    /// `doneHint`, when it's listening until "over", says so.
    case hearing(words: String, doneHint: String? = nil)
    /// Working out what it meant.
    case understanding
    /// Waiting on a spoken yes or no before doing something that can't be undone.
    case confirming

    public var isHearing: Bool {
        if case .hearing = self { return true }
        return false
    }

    var doneHint: String? {
        if case .hearing(_, let hint) = self { return hint }
        return nil
    }
}

/// A screen change asked for by voice.
public enum NavRequest: Equatable, Sendable {
    case reader(String)
    case summary(String)
    case pdf(String)
    case settings
    case back
    case home
}

/// How voice commands reach the navigation stack, which lives in the app's root view. Requests wait
/// here until it takes them, so a screen asked for with the phone locked is there when it's unlocked.
@MainActor
@Observable
public final class Navigator {
    public private(set) var request: NavRequest?
    /// The home screen should open its PDF picker.
    public private(set) var addPaperRequested = false

    public init() {}

    public func go(_ request: NavRequest) { self.request = request }
    public func handled() { request = nil }

    public func addPaper() {
        addPaperRequested = true
        go(.home)
    }

    public func addPaperHandled() { addPaperRequested = false }
}

/// The short sounds that say Albert heard something, with no screen to look at and without talking
/// over whoever's talking.
@MainActor
public protocol EarconPlayer: AnyObject {
    /// "I heard you, go on."
    func listening()
    /// "Done."
    func done()
    /// "Still working on it."
    func working()
    /// "Still listening: say over when you're done."
    func stillListening()
}

/// Albert: takes "Hey Albert", the Albert button or a follow-up to an answer through to the command
/// being carried out. audiopapers_core works out what was said (voice.py); this runs it, mostly by
/// calling ReadingEngine, and says something back, since there may be no screen to look at. Lives
/// for the whole process and runs on the main thread, like ReadingEngine.
///
/// Commands that need a screen (the PDF, Settings, picking a file) fall back to saying so when the
/// app isn't on screen, because iOS won't bring it there from the background.
@MainActor
@Observable
public final class VoiceController {
    public private(set) var state: VoiceState = .off
    /// True while listening for "Hey Albert": it works, and hearing works with the screen off, for
    /// the lock screen's button and for spoken answers to figure prompts.
    public private(set) var handsFree = false
    /// What was last heard and acted on, to show on screen.
    public private(set) var heard: String?
    /// The screen on top: "reader", "home", "summary", "pdf" or "settings".
    @ObservationIgnored public var screen = "home"

    @ObservationIgnored private let engine: ReadingEngine
    @ObservationIgnored private let speechInput: SpeechInput
    @ObservationIgnored private let navigator: Navigator
    @ObservationIgnored private let earcons: EarconPlayer
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let jobs: BackgroundJobs
    @ObservationIgnored private let micAllowed: () -> Bool
    @ObservationIgnored private let makeHandsFreePipeline: (@escaping @MainActor () -> Void, @escaping @MainActor (String) -> Void) -> MicPipeline

    @ObservationIgnored private var appVisible = false
    @ObservationIgnored private var muted = false
    @ObservationIgnored private var mutedUntilBack = false
    @ObservationIgnored private var onConfirmed: (@MainActor () async throws -> Void)?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var pipeline: MicPipeline?
    // A command turning into a question or a note, decided at a pause (see decideAtPause).
    @ObservationIgnored private var pauseDecision: Task<Void, Never>?
    @ObservationIgnored private var decidedAtPause: VoiceCommand?

    public init(
        engine: ReadingEngine,
        speechInput: SpeechInput,
        navigator: Navigator,
        earcons: EarconPlayer,
        notifier: Notifier,
        jobs: BackgroundJobs,
        micAllowed: @escaping () -> Bool,
        makeHandsFreePipeline: @escaping (@escaping @MainActor () -> Void, @escaping @MainActor (String) -> Void) -> MicPipeline
    ) {
        self.engine = engine
        self.speechInput = speechInput
        self.navigator = navigator
        self.earcons = earcons
        self.notifier = notifier
        self.jobs = jobs
        self.micAllowed = micAllowed
        self.makeHandsFreePipeline = makeHandsFreePipeline
        engine.onSessionChanged = { [weak self] paperId in
            guard let self else { return }
            if paperId == nil {
                muted = false
                mutedUntilBack = false
            }
            syncListening()
        }
        engine.onUnclearSpeech = { [weak self] in self?.onSpeechDuringPrompt($0) ?? false }
        engine.onPlayingChanged = { [weak self] playing in self?.playingChanged(playing) }
    }

    // MARK: - Whether the mic is on

    private func playingChanged(_ playing: Bool) {
        idleTask?.cancel()
        idleTask = nil
        if !playing {
            idleTask = Task {
                do {
                    try await sleepMs(idleStopMs)
                    stopForIdle()
                } catch {}
            }
        }
    }

    public func onAppVisible(_ visible: Bool) {
        appVisible = visible
        if visible {
            if mutedUntilBack {
                mutedUntilBack = false
                muted = false
            }
            syncListening()
        }
    }

    /// Starts or stops listening to match the setting and whether a paper is open. iOS only lets
    /// the microphone start while the app is on screen, so that's when it can.
    public func syncListening() {
        let wanted = Settings.heyAlbert && engine.paperId != nil && !muted && micAllowed()
        if wanted && !handsFree && appVisible {
            startHandsFree()
        } else if !wanted && handsFree {
            stopHandsFree()
        }
    }

    private func startHandsFree() {
        let pipeline = makeHandsFreePipeline(
            { [weak self] in self?.onWake() },
            { [weak self] in self?.onMicProblem($0) }
        )
        self.pipeline = pipeline
        speechInput.pipeline = pipeline
        pipeline.start()
        handsFree = true
        engine.announceProblems = true
        if state == .off { state = .waiting }
    }

    private func stopHandsFree() {
        pipeline?.stop()
        pipeline = nil
        speechInput.pipeline = nil
        handsFree = false
        engine.announceProblems = false
        if state == .waiting { state = .off }
    }

    /// "Stop listening", by voice: off until the paper closes or the Albert button is pressed.
    public func stopListening() {
        muted = true
        syncListening()
    }

    /// Off until the app is next on screen.
    public func stopUntilBack() {
        muted = true
        mutedUntilBack = true
        syncListening()
    }

    private func stopForIdle() {
        guard handsFree, state == .waiting else { return }
        Log.d("Paused for a long time, so no longer listening for Hey Albert")
        stopUntilBack()
        notifier.finished(
            key: "voice-idle",
            title: "Albert stopped listening",
            text: "The paper's been paused for a while. Albert listens again when you come back to the app."
        )
    }

    public func onMicProblem(_ problem: String) {
        say("\(problem) Tap the Albert button in the app to try again.")
    }

    // MARK: - Hearing something

    public func onWake() {
        // Whether a wake word heard right now should count: "Albert" is sometimes in the paper.
        guard state == .waiting, !engine.narrationSaysAlbert else {
            pipeline?.rearm()
            return
        }
        Log.d("Heard Hey Albert")
        beginCommand(fromWake: true)
    }

    /// The Albert button, in the app or on the lock screen: the same as saying "Hey Albert". While
    /// already listening, it means "that's all".
    public func pushToTalk() {
        switch state {
        case .hearing:
            speechInput.stop()
            return
        case .understanding, .confirming:
            return
        default:
            break
        }
        if muted {
            muted = false
            mutedUntilBack = false
            syncListening()
        }
        beginCommand(fromWake: false)
    }

    private func beginCommand(fromWake: Bool) {
        earcons.listening()
        engine.interruptForVoice()
        listenForCommand(.command, fromWake: fromWake)
    }

    private func listenForCommand(_ mode: ListenMode, fromWake: Bool = false) {
        pauseDecision?.cancel()
        decidedAtPause = nil
        state = .hearing(words: "")
        speechInput.listen(
            mode: mode,
            terms: engine.speechTerms(),
            fromWake: fromWake,
            untilOver: false,
            // A question or a note can only be about the paper that's open.
            onPause: Settings.sayOver && engine.paperId != nil ? { [weak self] in self?.decideAtPause($0) } : nil,
            onPartial: { [weak self] in self?.hearing($0) },
            onText: { [weak self] in self?.onHeard($0) },
            onFailure: { [weak self] problem in
                self?.settle()
                self?.say(problem)
            },
            onSayAgain: { [weak self] in
                self?.settle()
                self?.say("Sorry, say that again?") {
                    self?.engine.listeningAgain()
                    self?.listenForCommand(.command)
                }
            }
        )
    }

    private func settle() {
        pauseDecision?.cancel()
        state = handsFree ? .waiting : .off
    }

    private func hearing(_ words: String) {
        state = .hearing(words: words, doneHint: state.doneHint)
    }

    /// A pause in a command. If it's turning into a question or a note, listening carries on until
    /// "over"; anything else is finished. The fixed phrases are checked first, which is quick. If
    /// they don't cover it, Gemini decides while listening carries on, as it would have been asked
    /// anyway, and what it decides is kept for when the rest arrives.
    private func decideAtPause(_ text: String) {
        guard state.doneHint == nil, pauseDecision == nil else { return }
        pauseDecision = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { pauseDecision = nil } }
            let paperId = engine.paperId
            let answering = engine.followingUp
            let quick = try? await Core.interpretCommand(paperId, text, screen: screen, answering: answering, useGemini: false)
            guard !Task.isCancelled else { return }
            switch quick?.action {
            case "ask", "add_note":
                keepUntilOver(quick?.action == "add_note" ? noteDoneHint : questionDoneHint)
            case "unknown":
                keepUntilOver(questionDoneHint)
                guard let routed = try? await Core.interpretCommand(paperId, text, screen: screen, answering: answering),
                      !Task.isCancelled, state.isHearing else { return }
                switch routed.action {
                case "ask": decidedAtPause = routed
                case "add_note", "unknown": break
                default:
                    decidedAtPause = routed
                    speechInput.stop()
                }
            case "cancel":
                // Only "um" or the like so far: wait for the rest.
                if !onlyFiller(text) { speechInput.stop() }
            default:
                speechInput.stop()
            }
        }
    }

    private func onlyFiller(_ text: String) -> Bool {
        text.lowercased().split { !($0.isLetter || $0 == "'") }.allSatisfy { filler.contains(String($0)) }
    }

    private func keepUntilOver(_ hint: String) {
        guard case .hearing(let words, nil) = state else { return }
        speechInput.keepUntilOver()
        earcons.stillListening()
        state = .hearing(words: words, doneHint: hint)
    }

    private func onHeard(_ text: String?) {
        let decided = decidedAtPause
        decidedAtPause = nil
        pauseDecision?.cancel()
        pauseDecision = nil
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            settle()
            engine.voiceCancelled()
            return
        }
        heard = text
        Log.d("Heard: \(text)")
        state = .understanding
        Task {
            let command: VoiceCommand
            do {
                switch decided?.action {
                case nil:
                    command = try await Core.interpretCommand(engine.paperId, text, screen: screen, answering: engine.followingUp)
                case "ask":
                    // Gemini said it's a question: the whole of it, now it's here, tidied by the fixed
                    // phrases ("Hey Albert" off the front), which could still make it something else.
                    let local = try await Core.interpretCommand(engine.paperId, text, screen: screen, answering: engine.followingUp, useGemini: false)
                    var asked = decided!
                    asked.text = local.text ?? text
                    command = local.action == "unknown" ? asked : local
                default:
                    command = decided!
                }
            } catch let error as CoreError {
                settle()
                say(error.friendlyMessage)
                return
            } catch {
                settle()
                return
            }
            settle()
            Log.d("Command: \(command.action)")
            do {
                try await run(command)
            } catch let error as CoreError {
                say(error.friendlyMessage)
            } catch {}
        }
    }

    /// For trying things out with no microphone: on as if this had just been heard.
    public func actAsIfHeard(_ text: String) {
        engine.interruptForVoice()
        onHeard(text)
    }

    /// Something other than yes or no, said in answer to "Describe Figure 3, yes or no?".
    private func onSpeechDuringPrompt(_ text: String) -> Bool {
        guard handsFree else { return false }
        engine.interruptForVoice()
        onHeard(text)
        return true
    }

    // MARK: - Things said on purpose, from buttons

    /// The Ask button: whatever's said next is a question, with no working out what it means.
    public func askQuestion() {
        engine.startListening()
        hearQuestion()
    }

    /// The Follow up button on an answer.
    public func askFollowUp(_ answerId: String) {
        engine.startFollowUp(answerId)
        hearQuestion()
    }

    /// The Stop button while a question's being asked.
    public func stopHearing() {
        speechInput.stop()
    }

    private func hearQuestion() {
        let untilOver = Settings.sayOver
        state = .hearing(words: "", doneHint: untilOver ? questionDoneHint : nil)
        speechInput.listen(
            mode: .question,
            terms: engine.speechTerms(),
            fromWake: false,
            untilOver: untilOver,
            onPause: nil,
            onPartial: { [weak self] in self?.hearing($0) },
            onText: { [weak self] text in
                guard let self else { return }
                settle()
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    engine.submitQuestion(text)
                } else {
                    engine.cancelListening()
                }
            },
            onFailure: { [weak self] problem in
                self?.settle()
                self?.engine.listeningFailed(problem)
            },
            onSayAgain: { [weak self] in
                self?.settle()
                self?.engine.cancelListening()
            }
        )
    }

    // MARK: - Running a command

    private static let sessionActions = [
        "next_paragraph": "next_paragraph",
        "previous_paragraph": "previous_paragraph",
        "restart_paragraph": "restart_paragraph",
        "next_section": "skip",
        "previous_section": "back",
        "restart_section": "restart",
    ]

    private static let needsAPaper: Set<String> = [
        "pause", "resume", "next_paragraph", "previous_paragraph", "restart_paragraph", "next_section", "previous_section",
        "restart_section", "repeat", "faster", "slower", "set_speed", "describe_yes", "describe_no", "ask", "add_note", "take_note",
        "read_notes", "delete_last_note", "where_am_i", "recap", "read_summary", "go_to_section", "describe_figure", "open_summary",
        "open_pdf", "mark_read", "clear_paper", "remove_paper", "rename_paper", "prepare_audio",
    ]

    private func run(_ command: VoiceCommand) async throws {
        let paperId = engine.paperId ?? ""
        if engine.paperId == nil && VoiceController.needsAPaper.contains(command.action) {
            say("No paper is open. You can say open, and the paper's name.")
            return
        }
        switch command.action {
        case "pause":
            earcons.done()
            engine.endVoice(play: false)
        case "resume":
            earcons.done()
            engine.endVoice(play: true)
        case "stop":
            if engine.wasWaitingAfterAside {
                engine.endVoice(play: false)
            } else if engine.wasSpeakingAside {
                engine.dismissInterjection()
            } else {
                engine.endVoice(play: false)
            }
        case "cancel":
            engine.voiceCancelled()
        case "next_paragraph", "previous_paragraph", "restart_paragraph", "next_section", "previous_section", "restart_section":
            engine.voiceAct(VoiceController.sessionActions[command.action]!)
        case "repeat":
            if !engine.repeatAside() { engine.voiceAct("restart_paragraph") }
        case "faster":
            changeRate(engine.rate + ReadingEngine.rateStep)
        case "slower":
            changeRate(engine.rate - ReadingEngine.rateStep)
        case "set_speed":
            if let speed = command.speed { changeRate(speed) } else { engine.voiceCancelled() }
        case "describe_yes":
            engine.answerPrompt(yes: true)
        case "describe_no":
            engine.answerPrompt(yes: false)
        case "ask":
            if let question = command.text, !question.isEmpty { ask(question) } else { engine.voiceCancelled() }
        case "add_note":
            if let text = command.text { try await saveNote(paperId, text) } else { engine.voiceCancelled() }
        case "take_note":
            takeNote(paperId, todo: command.kind == "todo")
        case "read_notes":
            tell("Your notes", try await Core.spokenNotes(paperId))
        case "delete_last_note":
            let removed = try await Core.deleteLastNote(paperId)
            say(removed.map { "Deleted your last note: \($0.text)" } ?? "There's no note to delete.")
        case "where_am_i":
            say(try await Core.spokenPosition(paperId))
        case "recap":
            think { [self] in tell("Recap", try await Core.recap(paperId), waits: true) }
        case "read_summary":
            try await readSummary(paperId)
        case "go_to_section":
            if let index = command.sectionIndex {
                engine.goToSection(index)
            } else {
                say("I can't find \(command.query.map { "a section called \($0)" } ?? "that section") in this paper.")
            }
        case "describe_figure":
            describeFigure(paperId, command)
        case "open_summary":
            whenVisible("The summary needs the screen, but I can read it to you. Say read the summary.") { [self] in
                engine.leaveForAside()
                navigator.go(.summary(paperId))
            }
        case "open_pdf":
            whenVisible("The PDF needs the screen. It's there when you open the app.") { [self] in
                engine.leaveForAside()
                navigator.go(.pdf(paperId))
            }
        case "open_settings":
            whenVisible("Settings need the screen. They're there when you open the app.") { [self] in
                engine.leaveForAside()
                navigator.go(.settings)
            }
        case "close_screen":
            engine.voiceCancelled()
            navigator.go(.back)
        case "go_home":
            earcons.done()
            engine.close(engine.paperId)
            engine.voiceCancelled()
            navigator.go(.home)
        case "list_papers":
            tell("Your papers", try await Core.spokenPapers())
        case "open_paper":
            if let target = command.paperId { openPaper(target) } else { engine.voiceCancelled() }
        case "mark_read":
            earcons.done()
            engine.markRead()
        case "clear_paper":
            confirm("Clear your notes and your place in this paper?") { [self] in
                try await engine.clearPaper()
            }
        case "remove_paper":
            confirm("Remove this paper and everything saved for it?") { [self] in
                engine.close(paperId)
                try await Core.deletePaper(paperId)
                navigator.go(.home)
                say("Removed.")
            }
        case "rename_paper":
            if let name = command.text { try await renamePaper(paperId, name) } else { engine.voiceCancelled() }
        case "add_paper":
            whenVisible("Picking a PDF needs the screen. You can do that when you open the app.") { [self] in
                engine.close(engine.paperId)
                engine.voiceCancelled()
                navigator.addPaper()
            }
        case "prepare_audio":
            jobs.downloadAudio(paperId)
            say("Preparing this paper's audio in the background.")
        case "set_setting":
            changeSetting(command)
        case "set_voice":
            changeVoice(command.value?.content)
        case "stop_listening":
            say("Okay. Press the Albert button in the app when you want me back.")
            stopListening()
        case "help":
            tell("What you can say", command.text ?? "")
        default:
            say(
                Settings.geminiKey == nil
                    ? "I only know the built-in commands without a Gemini key, and that wasn't one."
                    : "Sorry, I didn't get that."
            )
        }
    }

    private func say(_ text: String, then: (() -> Void)? = nil) {
        engine.tell(ReadingEngine.shortReply, text, voice: .phone, then: then)
    }

    private func tell(_ title: String, _ text: String, waits: Bool = false) {
        engine.tell(title, text, voice: Voice.live(), waits: waits)
    }

    private func changeRate(_ rate: Float) {
        engine.setRate(max(ReadingEngine.minRate, min(ReadingEngine.maxRate, rate)))
        earcons.done()
        engine.voiceCancelled()
    }

    private func ask(_ question: String) {
        engine.submitQuestion(question, acknowledge: true)
        soundWhileThinking()
    }

    private func think(_ work: @escaping @MainActor () async throws -> Void) {
        engine.think(acknowledge: true, work)
        soundWhileThinking()
    }

    private func soundWhileThinking() {
        Task {
            do {
                try await sleepMs(workingSoundEveryMs)
                while engine.interjectionState == .thinking {
                    earcons.working()
                    try await sleepMs(workingSoundEveryMs)
                }
            } catch {}
        }
    }

    private func saveNote(_ paperId: String, _ text: String) async throws {
        let note = try await Core.addNote(paperId, text)
        say(note.kind == "todo" ? "Added to your to dos." : "Noted.")
    }

    private func takeNote(_ paperId: String, todo: Bool) {
        let untilOver = Settings.sayOver
        let prompt = todo ? "What's the to do?" : "Go ahead."
        say(untilOver ? "\(prompt) Say over when you're done." : prompt) { [weak self] in
            guard let self else { return }
            engine.listeningAgain()
            state = .hearing(words: "", doneHint: untilOver ? noteDoneHint : nil)
            speechInput.listen(
                mode: .dictation,
                terms: engine.speechTerms(),
                fromWake: false,
                untilOver: untilOver,
                onPause: nil,
                onPartial: { [weak self] in self?.hearing($0) },
                onText: { [weak self] text in
                    guard let self else { return }
                    settle()
                    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        say("I didn't hear anything, so I haven't saved a note.")
                        return
                    }
                    heard = text
                    Task {
                        do {
                            try await self.saveNote(paperId, todo ? "todo: \(text)" : text)
                        } catch let error as CoreError {
                            self.say(error.friendlyMessage)
                        } catch {}
                    }
                },
                onFailure: { [weak self] problem in
                    self?.settle()
                    self?.say(problem)
                },
                onSayAgain: { [weak self] in
                    self?.settle()
                    self?.say("I didn't catch that, so I haven't saved a note.")
                }
            )
        }
    }

    /// The same words and voice as the summary screen's speaker button.
    private func readSummary(_ paperId: String) async throws {
        if let written = try await Core.getSummary(paperId) {
            engine.tell("Summary", try await Core.summarySpeechText(written), voice: Voice.summary(), waits: true)
        } else {
            think { [self] in
                let summary = try await Core.generateSummary(paperId)
                engine.tell("Summary", try await Core.summarySpeechText(summary), voice: Voice.summary(), waits: true)
            }
        }
    }

    private func describeFigure(_ paperId: String, _ command: VoiceCommand) {
        guard let figureId = command.figureId else {
            say("I can't find \(command.figureLabel ?? "that") in this paper.")
            return
        }
        think { [self] in
            let description = try await Core.figureDescription(paperId, figureId)
            engine.tell(description.label, description.text, voice: Voice.live(), audioId: "desc_\(figureId)", figureId: figureId)
        }
    }

    private func whenVisible(_ otherwise: String, _ action: () -> Void) {
        if appVisible { action() } else { say(otherwise) }
    }

    private func confirm(_ question: String, onYes: @escaping @MainActor () async throws -> Void) {
        onConfirmed = onYes
        state = .confirming
        say("\(question) Say yes or no.") { [weak self] in
            self?.engine.listeningAgain()
            self?.hearConfirmation(tries: 2)
        }
    }

    private func hearConfirmation(tries: Int) {
        speechInput.listen(
            mode: .yesNo,
            terms: [],
            fromWake: false,
            onPartial: { _ in },
            onText: { [weak self] text in
                Task { [weak self] in
                    let answer = (try? await Core.yesOrNo(text)) ?? nil
                    self?.onConfirmationAnswer(answer, tries: tries)
                }
            },
            onFailure: { [weak self] _ in self?.leaveAlone() },
            onSayAgain: { [weak self] in self?.leaveAlone() }
        )
    }

    private func onConfirmationAnswer(_ answer: Bool?, tries: Int) {
        switch answer {
        case true?:
            let action = onConfirmed
            onConfirmed = nil
            settle()
            Task {
                do {
                    try await action?()
                } catch let error as CoreError {
                    say(error.friendlyMessage)
                } catch {}
            }
        case false?:
            leaveAlone()
        case nil:
            if tries > 1 { hearConfirmation(tries: tries - 1) } else { leaveAlone() }
        }
    }

    private func leaveAlone() {
        onConfirmed = nil
        settle()
        say("Okay, leaving it as it is.")
    }

    private func openPaper(_ target: String) {
        if target == engine.paperId {
            say("That's the one that's open.")
            return
        }
        let voice = Voice.current()
        if voice.isKokoro && OfflineAudio.readyVoice(target) != voice.label {
            say("That paper's audio isn't prepared yet for this voice. Open the app to prepare it, or say use the phone voice.")
            return
        }
        engine.open(target)
        navigator.go(.reader(target))
    }

    private func renamePaper(_ paperId: String, _ name: String) async throws {
        let renamed = try await Core.renamePaper(paperId, name).paperId
        earcons.done()
        engine.reopenAs(paperId, renamed)
        navigator.go(.reader(renamed))
    }

    private func changeSetting(_ command: VoiceCommand) {
        let on = command.value?.content == "true"
        switch command.setting {
        case "ask_about_figures":
            Settings.askAboutFigures = on
            say(on ? "Okay, I'll ask about figures." : "Okay, I won't ask about figures.")
        case "highlight_spoken":
            Settings.highlightSpoken = on
            say(on ? "Highlighting is on." : "Highlighting is off.")
        case "follow_spoken":
            Settings.followSpoken = on
            say(on ? "Scrolling is on." : "Scrolling is off.")
        default:
            engine.voiceCancelled()
        }
    }

    private func changeVoice(_ name: String?) {
        let chosen = name.flatMap(VoiceEngine.init)
        if chosen == nil {
            engine.voiceCancelled()
        } else if chosen == .gemini && Settings.geminiKey == nil {
            say("The Gemini voice needs a Gemini key.")
        } else {
            Settings.voiceEngine = chosen!
            say("Okay, that voice is on from the next paragraph.")
        }
    }
}
