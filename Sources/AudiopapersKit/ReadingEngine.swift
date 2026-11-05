import Foundation
import Observation

public enum ReaderUiState: Equatable, Sendable {
    case loading
    case ready(SessionView)
    case error(String)

    public var session: SessionView? {
        if case .ready(let session) = self { return session }
        return nil
    }
}

/// A question asked mid-session -- separate from ReaderUiState since it doesn't move the reading
/// position, just plays an answer on top of wherever narration was.
public enum InterjectionState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case answered(question: String, answer: String, audioId: String, answerId: String)
    /// Albert saying something that isn't an answer: a recap, the listener's notes, a figure
    /// described on request, a short reply to a command. `figureId` is the figure it's about.
    case telling(title: String, text: String, audioId: String, figureId: String?)
    case failed(String)
}

/// Reading the summary aloud: nothing yet, its audio being rendered, or loaded in the player.
public enum SummarySpeech: Sendable { case off, preparing, ready }

public enum PlayerState: Sendable { case idle, ready, ended }

/// One audio file to play, and what the lock screen says about it.
public struct PlayerItem: Equatable, Sendable {
    public var url: URL
    public var mediaId: String
    public var title: String
    public var artist: String?

    public init(url: URL, mediaId: String, title: String, artist: String?) {
        self.url = url
        self.mediaId = mediaId
        self.title = title
        self.artist = artist
    }
}

/// What ReadingEngine needs of a player: a list of files played in order at a rate. On iOS it's an
/// AVAudioEngine graph, shared with the microphone so echo cancelling knows what's being played.
@MainActor
public protocol PlayerBackend: AnyObject {
    /// Whether it plays as soon as it has audio, as opposed to staying paused.
    var playWhenReady: Bool { get set }
    var isPlaying: Bool { get }
    var state: PlayerState { get }
    var itemCount: Int { get }
    var currentIndex: Int { get }
    var currentPositionMs: Int64 { get }
    /// The current item's length; 0 if there isn't one.
    var durationMs: Int64 { get }

    func setItems(_ items: [PlayerItem], index: Int, positionMs: Int64)
    func addItem(_ item: PlayerItem)
    func seek(index: Int, positionMs: Int64)
    func play()
    func pause()
    /// Stops and forgets every item.
    func stop()
    func setRate(_ rate: Float)
    func setCurrentTitle(_ title: String)

    var onIsPlayingChanged: ((Bool) -> Void)? { get set }
    var onEnded: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
}

private let prefetchSegments = 2
// Silence before a new section starts, so the change of section can be heard.
private let sectionGapMs: Int64 = 2_000
// Times a describe prompt is asked aloud without a clear yes or no before it's left to the
// on-screen buttons -- the listener may have walked away.
private let maxSpokenAsks = 3
private let summaryAudioId = "summary"
private let sayPrefix = "say_"
private let maxSpeechTerms = 60
private let leadingNumber = try! NSRegularExpression(pattern: "^[0-9IVXLCDM.]+[.):\\s]+")

/// Owns the player and drives one paper's reading session. Lives for the whole process rather than
/// inside the reader screen, so narration -- including advancing segment to segment -- keeps going
/// with the screen locked.
///
/// Everything about the paper comes from audiopapers_core (see Core): what to say next, whether to
/// ask about a figure, answers to questions. Audio comes from Speech: the phone's own text-to-speech
/// (offline once a paper is ingested) or, if chosen in Settings, a Gemini voice or the on-device
/// Kokoro voice. Describing a figure and answering a question also call Gemini.
@MainActor
@Observable
public final class ReadingEngine {
    public static let rateStep: Float = 0.25
    public static let minRate: Float = 0.5
    public static let maxRate: Float = 3
    /// The title of something short Albert says, which needs no dialog on screen.
    public static let shortReply = "Albert"

    public private(set) var uiState: ReaderUiState = .loading
    public private(set) var interjectionState: InterjectionState = .idle
    /// True while "describe_yes" runs -- a real, multi-second Gemini call.
    public private(set) var isDescribing = false
    /// True while the mic is open for a spoken yes or no to a describe prompt.
    public private(set) var listeningForAnswer = false
    public private(set) var isPlaying = false
    public private(set) var rate: Float = 1
    public private(set) var summarySpeech: SummarySpeech = .off
    /// A one-off problem worth telling the listener about that doesn't end the session.
    public private(set) var message: String?
    public private(set) var paperId: String?

    /// Told when a paper opens (with its id) or closes (with nil); see VoiceController.
    @ObservationIgnored public var onSessionChanged: ((String?) -> Void)?
    /// Given an answer that's just finished being read out; true if it's taken care of what
    /// happens next, which is otherwise going back to the narration.
    @ObservationIgnored public var onAnswerFinished: ((_ answerId: String) -> Bool)?
    /// Given what was said to a describe prompt when it wasn't yes or no; true if it's been taken
    /// care of, otherwise the prompt is asked again.
    @ObservationIgnored public var onUnclearSpeech: ((String) -> Bool)?
    /// Told whenever playing starts or stops; see VoiceController's idle timeout.
    @ObservationIgnored public var onPlayingChanged: ((Bool) -> Void)?
    /// Say problems out loud as well as showing them, for when there may be no screen to see them
    /// on. A failed question then also moves on by itself rather than waiting for a tap.
    @ObservationIgnored public var announceProblems = false

    @ObservationIgnored private let player: PlayerBackend
    @ObservationIgnored private let speech: Speech
    @ObservationIgnored private let speechInput: SpeechListening
    @ObservationIgnored private let micAllowed: () -> Bool
    @ObservationIgnored private let scratchDir: URL

    @ObservationIgnored private var narration: [NarrationSegment] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var playbackRunning = false
    @ObservationIgnored private var playbackGeneration = 0
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// A question or other spoken request being worked on.
    @ObservationIgnored private var thinkingTask: Task<Void, Never>?

    /// Which audio the player has loaded, so a natural end only advances the session when it's the
    /// audio the session is actually on.
    @ObservationIgnored private var loadedAudioId: String?
    /// Where narration was when a question interrupted it, to resume in place.
    @ObservationIgnored private var pausedAudioId: String?
    @ObservationIgnored private var pausedItemIndex = 0
    @ObservationIgnored private var pausedPositionMs: Int64 = 0
    /// Whether narration was going (or about to) when something interrupted it, so it stays paused
    /// afterwards if the listener had paused it.
    @ObservationIgnored private var keepPlaying = true
    /// What's to be played once it's rendered: false holds it paused when it's ready.
    @ObservationIgnored private var autoPlay = true
    /// Whether the player has actually been given the audio `loadedAudioId` names yet.
    @ObservationIgnored private var audioLoaded = false
    /// The words of the audio `loadedAudioId` names.
    @ObservationIgnored private var loadedText = ""
    /// The answer or other aside a voice command interrupted, to carry on with if it turns out
    /// nothing was meant by it.
    @ObservationIgnored private var interruptedAside: InterjectionState?
    /// What to do when the aside being told has finished, instead of going back to narration.
    @ObservationIgnored private var afterTelling: (() -> Void)?
    /// Set while narration is paused for a note or the summary and should resume after.
    @ObservationIgnored private var resumeAfterAside = false
    /// The answer a question being asked follows up on (see startFollowUp), if any.
    @ObservationIgnored private var followUpOf: String?
    /// Moves through the paper happen in the order they were asked for.
    @ObservationIgnored private let sessionCalls = AsyncLock()
    @ObservationIgnored private var lastAnnouncedProblem: String?
    /// The prompt that's been asked aloud, so re-applying the same session (e.g. after a question
    /// is answered) doesn't ask it again. Cleared by any action.
    @ObservationIgnored private var askedPrompt: PendingPrompt?
    @ObservationIgnored private var spokenAsks = 0
    /// The section narration just finished in, when it moved on by itself (see act).
    @ObservationIgnored private var sectionGapFrom: Int?
    /// Characters of text in each part of the loaded audio (see Speech.partTexts).
    @ObservationIgnored private var partLengths: [Int] = []

    public init(player: PlayerBackend, speech: Speech, speechInput: SpeechListening, micAllowed: @escaping () -> Bool, scratchDir: URL) {
        self.player = player
        self.speech = speech
        self.speechInput = speechInput
        self.micAllowed = micAllowed
        self.scratchDir = scratchDir
        speech.onGeminiUnavailable = { [weak self] in self?.reportProblem($0) }
        player.onIsPlayingChanged = { [weak self] playing in
            self?.isPlaying = playing
            self?.onPlayingChanged?(playing)
        }
        player.onEnded = { [weak self] in self?.onAudioEnded() }
        player.onError = { [weak self] in self?.reportProblem("Playback failed: \($0)") }
    }

    /// Starts (or rejoins) a reading session. Rejoining the paper that's already playing leaves
    /// playback untouched.
    public func open(_ paperId: String) {
        if self.paperId == paperId {
            if case .error = uiState {} else { return }
        }
        endSession()
        self.paperId = paperId
        speech.resumeGemini() // a new session gives the Gemini voice another try
        setRate(Settings.playbackRate)
        load()
        onSessionChanged?(paperId)
    }

    /// Ends the session for `paperId` (a no-op if a different paper is open).
    public func close(_ paperId: String?) {
        guard let paperId, paperId == self.paperId else { return }
        endSession()
        onSessionChanged?(nil)
    }

    private func endSession() {
        loadTask?.cancel()
        actionTask?.cancel()
        cancelPlayback()
        prefetchTask?.cancel()
        thinkingTask?.cancel()
        stopAsking()
        player.stop()
        loadedAudioId = nil
        loadedText = ""
        audioLoaded = false
        pausedAudioId = nil
        keepPlaying = true
        autoPlay = true
        resumeAfterAside = false
        followUpOf = nil
        interruptedAside = nil
        afterTelling = nil
        lastAnnouncedProblem = nil
        narration = []
        paperId = nil
        uiState = .loading
        interjectionState = .idle
        isDescribing = false
        summarySpeech = .off
        message = nil
    }

    /// Carries on with a paper that's just been renamed. Its place is saved under the new name.
    public func reopenAs(_ oldPaperId: String, _ newPaperId: String) {
        guard oldPaperId == paperId else { return }
        endSession()
        paperId = newPaperId
        load()
        onSessionChanged?(newPaperId)
    }

    public func retryLoad() {
        if paperId != nil { load() }
    }

    private func load() {
        guard let id = paperId else { return }
        loadTask?.cancel()
        uiState = .loading
        loadTask = Task {
            do {
                narration = try await Core.narration(id)
                applySession(try await Core.paperDetail(id).session)
            } catch let error as CoreError {
                uiState = .error(error.friendlyMessage)
            } catch {}
        }
    }

    /// Moves on as if the current audio had finished (stopping at any figure prompt).
    public func next() { act("next") }
    public func restartParagraph() { act("restart_paragraph") }
    public func previousParagraph() { act("previous_paragraph") }
    public func nextParagraph() { act("next_paragraph") }
    public func restartSection() { act("restart") }
    public func previousSection() { act("back") }
    public func nextSection() { act("skip") }
    public func describeNo() { act("describe_no") }

    public func describeYes() {
        isDescribing = true
        act("describe_yes", onDone: { [weak self] in self?.isDescribing = false })
    }

    /// "Next" from a Bluetooth/car/lock-screen button: answers a pending describe prompt with "no"
    /// (keep listening) rather than advancing past it.
    public func nextFromMediaButton() {
        if uiState.session?.pendingPrompt != nil { describeNo() } else { next() }
    }

    /// Pauses for something the listener is doing on the side (writing a note, reading the
    /// summary). `endAside` resumes, but only if narration was playing to begin with.
    public func pauseForAside() {
        if narrationGoing() { resumeAfterAside = true }
        holdPlayback()
    }

    public func endAside() {
        let resume = resumeAfterAside
        resumeAfterAside = false
        if speakingSummary {
            leaveSummary(resume: resume)
        } else if resume {
            autoPlay = true
            player.play()
        }
    }

    // MARK: - Reading the summary aloud

    private var speakingSummary: Bool { loadedAudioId == summaryAudioId }

    /// The summary screen's button: starts reading `text`, pauses or resumes it, or gives up on it
    /// while it's still being rendered. Narration's place is kept for `endAside`.
    public func toggleSummary(_ text: String) {
        switch summarySpeech {
        case .off: startSummary(text)
        case .preparing:
            cancelPlayback()
            summarySpeech = .off
        case .ready: togglePlayPause()
        }
    }

    private func startSummary(_ text: String) {
        stopAsking()
        if !speakingSummary { rememberPlace() }
        player.pause()
        summarySpeech = .preparing
        speak(summaryAudioId, text, title: "Summary", voice: Voice.summary())
    }

    /// Back from the summary after hearing it: puts narration back where it was, playing only if it
    /// was playing before the summary screen opened.
    private func leaveSummary(resume: Bool) {
        cancelPlayback()
        player.stop()
        loadedAudioId = nil
        audioLoaded = false
        keepPlaying = true
        summarySpeech = .off
        if interjectionState == .idle, let session = uiState.session {
            startSessionPlayback(session, play: resume)
        }
    }

    public func togglePlayPause() {
        if player.isPlaying {
            holdPlayback()
        } else {
            autoPlay = true
            player.play()
        }
    }

    /// For the lock screen, which says which it wants.
    public func setPlaying(_ playing: Bool) {
        if playing != player.isPlaying { togglePlayPause() }
    }

    /// Whether narration is going, or waiting to start: in the gap before a new section, or for its
    /// first part to be rendered.
    private func narrationGoing() -> Bool { startPending ? autoPlay : player.playWhenReady }

    private var startPending: Bool { playbackRunning && !audioLoaded }

    /// Pauses now, and holds anything still waiting to start, which the player knows nothing about
    /// yet.
    private func holdPlayback() {
        autoPlay = false
        player.pause()
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        Settings.playbackRate = rate
        player.setRate(rate)
    }

    public func dismissMessage() {
        message = nil
    }

    /// `naturalFromSection` is set when narration moves on by itself (the audio ended), so a new
    /// section can start after a pause; anything the listener taps starts right away.
    private func act(_ action: String, onDone: @escaping () -> Void = {}, naturalFromSection: Int? = nil) {
        guard let id = paperId else { return }
        // A headset's skip buttons, or a lock-screen answer, can't move narration from under the
        // summary; it comes back when the summary screen is left.
        if speakingSummary { return onDone() }
        stopAsking()
        sectionGapFrom = naturalFromSection
        actionTask?.cancel()
        actionTask = Task {
            defer { onDone() }
            do {
                let session = try await sessionCalls.withLock { try await Core.sessionAction(id, action) }
                try Task.checkCancellation()
                applySession(session)
            } catch let error as CoreError {
                reportProblem(error.friendlyMessage)
            } catch {}
        }
    }

    /// A problem worth telling the listener about that doesn't end the session.
    private func reportProblem(_ problem: String) {
        message = problem
        // Once each: if the problem is that nothing can be spoken at all, then saying so fails,
        // narration comes back, fails the same way, and this would otherwise go round forever.
        if announceProblems && interjectionState == .idle && problem != lastAnnouncedProblem {
            lastAnnouncedProblem = problem
            tell(ReadingEngine.shortReply, problem, voice: .phone)
        }
    }

    // MARK: - Questions

    /// Called when the mic starts listening for a question (see VoiceController). Pauses narration
    /// and remembers where, to resume in place.
    public func startListening() {
        stopAsking()
        followUpOf = nil
        rememberPlace()
        interjectionState = .listening
    }

    /// Stops narration and notes where it was. Audio still waiting to start (in the gap before a
    /// new section, or being rendered) hasn't begun, so that's where it'll start from.
    private func rememberPlace() {
        keepPlaying = narrationGoing()
        if audioLoaded {
            pausedAudioId = loadedAudioId
            pausedItemIndex = player.currentIndex
            pausedPositionMs = player.currentPositionMs
        } else {
            pausedAudioId = nil
        }
        cancelPlayback()
        holdPlayback()
    }

    /// Whether a question being asked now would follow up on an earlier answer.
    public var followingUp: Bool { followUpOf != nil }

    /// Called when the mic starts listening for a follow-up to the answer `answerId`. The narration
    /// was already paused (and its place remembered) by the first question.
    public func startFollowUp(_ answerId: String) {
        stopAsking()
        followUpOf = answerId
        interruptedAside = nil
        cancelPlayback()
        holdPlayback()
        interjectionState = .listening
    }

    /// Called when something might have been said to Albert, whatever was going on at the time.
    /// Nothing's lost if it turns out nothing was: see `voiceCancelled`.
    public func interruptForVoice() {
        let current = interjectionState
        switch current {
        case .listening:
            return
        case .idle:
            followUpOf = nil
            rememberPlace()
        case .answered(_, _, _, let answerId):
            interruptedAside = current
            followUpOf = answerId
            holdPlayback()
        case .telling:
            interruptedAside = current
            holdPlayback()
        // Asking over a question still being answered means the listener's moved on.
        case .thinking, .failed:
            thinkingTask?.cancel()
            cancelPlayback()
            holdPlayback()
        }
        stopAsking()
        interjectionState = .listening
    }

    /// Nothing was said after all, or it was "never mind": carries on with whatever was
    /// interrupted, as it was.
    public func voiceCancelled() {
        guard let aside = interruptedAside else {
            cancelListening()
            return
        }
        interruptedAside = nil
        interjectionState = aside
        autoPlay = true
        if player.state == .ended && !renderingParts { finishAside() } else { player.play() }
    }

    public func cancelListening() {
        followUpOf = nil
        afterTelling = nil
        interjectionState = .idle
        resumeSession()
    }

    /// Ends a voice command that didn't change the reading position, with narration back where it
    /// was. `play` overrides whether it was going beforehand.
    public func endVoice(play: Bool? = nil) {
        followUpOf = nil
        interruptedAside = nil
        afterTelling = nil
        if let play { keepPlaying = play }
        interjectionState = .idle
        resumeSession()
    }

    /// Whether a voice command interrupted an answer or other aside being read out.
    public var wasSpeakingAside: Bool { interruptedAside != nil }

    /// Carries on listening after Albert has asked for something.
    public func listeningAgain() {
        interruptedAside = nil
        interjectionState = .listening
    }

    /// A move through the paper asked for by voice.
    public func voiceAct(_ action: String) {
        leaveVoiceForMove()
        act(action)
    }

    private func leaveVoiceForMove() {
        followUpOf = nil
        interruptedAside = nil
        afterTelling = nil
        pausedAudioId = nil
        keepPlaying = true
        interjectionState = .idle
    }

    /// Jumps to a section, by its place among the narrated ones.
    public func goToSection(_ index: Int) {
        guard let id = paperId else { return }
        leaveVoiceForMove()
        stopAsking()
        sectionGapFrom = nil
        actionTask?.cancel()
        actionTask = Task {
            do {
                let session = try await sessionCalls.withLock { try await Core.seek(id, index) }
                try Task.checkCancellation()
                applySession(session)
            } catch let error as CoreError {
                reportProblem(error.friendlyMessage)
            } catch {}
        }
    }

    /// Answers a pending describe prompt with a spoken yes or no.
    public func answerPrompt(yes: Bool) {
        leaveVoiceForMove()
        if yes { describeYes() } else { describeNo() }
    }

    /// Reads the interrupted aside again from the top; false if there isn't one.
    public func repeatAside() -> Bool {
        guard let aside = interruptedAside else { return false }
        interruptedAside = nil
        interjectionState = aside
        autoPlay = true
        player.seek(index: 0, positionMs: 0)
        player.play()
        return true
    }

    /// Leaves for another screen on a voice command, to come back to as the buttons would.
    public func leaveForAside() {
        let wasGoing = keepPlaying
        endVoice(play: false)
        resumeAfterAside = wasGoing
    }

    public func markRead() {
        guard let id = paperId else { return }
        leaveVoiceForMove()
        Task {
            do {
                applySession(try await sessionCalls.withLock { try await Core.markRead(id) })
            } catch let error as CoreError {
                reportProblem(error.friendlyMessage)
            } catch {}
        }
    }

    /// Back to the start of this paper, its notes gone.
    public func clearPaper() async throws {
        guard let id = paperId else { return }
        leaveVoiceForMove()
        applySession(try await sessionCalls.withLock { try await Core.clearPaper(id) })
    }

    /// Words worth favouring when listening, for the speech recognizer: this paper's headings.
    public func speechTerms() -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for segment in narration {
            guard let title = segment.sectionTitle else { continue }
            let range = NSRange(title.startIndex..., in: title)
            let stripped = leadingNumber.stringByReplacingMatches(in: title, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty && seen.insert(stripped).inserted { terms.append(stripped) }
        }
        return Array(terms.prefix(maxSpeechTerms))
    }

    /// Whether what's being read out says "Albert" itself, where the wake word shouldn't count:
    /// ALBERT is a BERT variant, and plenty of authors are called it.
    public var narrationSaysAlbert: Bool { isPlaying && loadedText.range(of: "albert", options: .caseInsensitive) != nil }

    /// Speech recognition failed; shown until dismissed, then narration resumes.
    public func listeningFailed(_ problem: String) { fail(problem) }

    /// Answers a transcribed question with Gemini, grounded in the paper and the current position,
    /// and speaks the answer. `acknowledge` says so out loud in the meantime, for someone with no
    /// screen to see "Thinking..." on.
    public func submitQuestion(_ question: String, acknowledge: Bool = false) {
        guard let id = paperId else { return }
        interruptedAside = nil
        think(acknowledge: acknowledge) { [self] in
            let result = try await Core.answer(id, question, followUpOf: followUpOf)
            try Task.checkCancellation()
            followUpOf = nil
            let audioId = "answer_\(result.answerId)"
            interjectionState = .answered(question: result.question, answer: result.answer, audioId: audioId, answerId: result.answerId)
            speak(audioId, result.answer, title: "Answer: \(result.question)", voice: Voice.live())
        }
    }

    /// Runs something that takes a while and ends by saying something (an answer, a recap).
    public func think(acknowledge: Bool = false, _ work: @escaping @MainActor () async throws -> Void) {
        interruptedAside = nil
        afterTelling = nil
        interjectionState = .thinking
        if acknowledge { speak("\(sayPrefix)checking", "Let me check.", title: "Thinking", voice: .phone) }
        thinkingTask?.cancel()
        thinkingTask = Task {
            do {
                try await work()
            } catch let error as CoreError {
                fail(error.friendlyMessage)
            } catch {}
        }
    }

    private func fail(_ problem: String) {
        interjectionState = .failed(problem)
        if announceProblems { speak(sayAudioId(problem), problem, title: ReadingEngine.shortReply, voice: .phone) }
    }

    /// Says something on top of wherever narration was, which carries on afterwards as it would
    /// after an answer; `then` runs instead, if given. Works with no paper open, too.
    public func tell(_ title: String, _ text: String, voice: Voice, audioId: String? = nil, figureId: String? = nil, then: (() -> Void)? = nil) {
        if interjectionState == .idle {
            followUpOf = nil
            stopAsking()
            rememberPlace()
        }
        let audioId = audioId ?? sayAudioId(text)
        interruptedAside = nil
        afterTelling = then
        interjectionState = .telling(title: title, text: text, audioId: audioId, figureId: figureId)
        speak(audioId, text, title: title, voice: voice)
    }

    private func sayAudioId(_ text: String) -> String { sayPrefix + stableHash(text) }

    /// An answer or other aside is over, or couldn't be read out: on to whatever comes next.
    private func finishAside() {
        switch interjectionState {
        case .answered(_, _, _, let answerId):
            if onAnswerFinished?(answerId) != true { dismissInterjection() }
        case .telling:
            let then = afterTelling
            afterTelling = nil
            if let then { then() } else { dismissInterjection() }
        case .failed:
            dismissInterjection()
        default:
            break
        }
    }

    /// Where the paragraph being read is in the PDF: the page its section starts on, and its text,
    /// to find it on the page. Nils when unknown (e.g. the paper is finished).
    public func currentParagraph() -> (page: Int?, text: String?) {
        guard let session = uiState.session else { return (nil, nil) }
        let audioId = "seg_\(session.sectionIndex)_\(session.segmentIndex)"
        return (session.sectionPage, narration.first { $0.audioId == audioId }?.text)
    }

    /// Returns to narration after an answer finishes or is dismissed.
    public func dismissInterjection() {
        followUpOf = nil
        interruptedAside = nil
        afterTelling = nil
        interjectionState = .idle
        resumeSession()
    }

    /// Saves a note/TODO tagged with the session's current position.
    public func addNote(_ text: String) {
        guard let id = paperId else { return }
        Task {
            do {
                _ = try await Core.addNote(id, text)
            } catch let error as CoreError {
                reportProblem(error.friendlyMessage)
            } catch {}
        }
    }

    // MARK: - Describe prompts asked aloud

    private func askAudioId(_ prompt: PendingPrompt) -> String {
        var slug = ""
        var inGap = false
        for scalar in prompt.label.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                slug.unicodeScalars.append(scalar)
                inGap = false
            } else if !inGap {
                slug.append("_")
                inGap = true
            }
        }
        return "ask_" + slug
    }

    /// Says "Describe figure 3, yes or no?", then listens for the answer (see onAudioEnded). The
    /// on-screen Yes and No buttons keep working throughout.
    private func askAloud(_ prompt: PendingPrompt) {
        if askedPrompt == prompt { return }
        askedPrompt = prompt
        spokenAsks = 0
        sayPrompt(prompt)
    }

    private func sayPrompt(_ prompt: PendingPrompt) {
        spokenAsks += 1
        speak(askAudioId(prompt), "Describe \(prompt.label), yes or no?", title: "Describe \(prompt.label)?", voice: Voice.live())
    }

    private func listenForAnswer() {
        guard micAllowed(), speechInput.isAvailable else { return } // the buttons still work
        listeningForAnswer = true
        speechInput.listen(
            mode: .yesNo,
            terms: [],
            fromWake: false,
            onPartial: { _ in },
            onText: { [weak self] in self?.onSpokenAnswer($0) },
            onFailure: { [weak self] _ in self?.listeningForAnswer = false },
            onSayAgain: { [weak self] in self?.onSpokenAnswer(nil) }
        )
    }

    private func onSpokenAnswer(_ text: String?) {
        listeningForAnswer = false
        guard let prompt = askedPrompt else { return }
        Task {
            let answer = (try? await Core.yesOrNo(text)) ?? nil
            guard askedPrompt == prompt else { return }
            switch answer {
            case true?: describeYes()
            case false?: describeNo()
            case nil:
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onUnclearSpeech?(text) == true { return }
                if spokenAsks < maxSpokenAsks { sayPrompt(prompt) } // anything else (or nothing): ask again
            }
        }
    }

    private func stopAsking() {
        if listeningForAnswer { speechInput.cancel() }
        listeningForAnswer = false
        askedPrompt = nil
    }

    // MARK: - Playback

    private func cancelPlayback() {
        playbackTask?.cancel()
        playbackRunning = false
    }

    private func applySession(_ session: SessionView) {
        uiState = .ready(session)
        if interjectionState == .idle && !speakingSummary { startSessionPlayback(session) }
    }

    private func resumeSession() {
        let play = keepPlaying
        keepPlaying = true
        if let session = uiState.session { startSessionPlayback(session, play: play) }
    }

    /// `play` false leaves it loaded and paused: the listener had paused it.
    private func startSessionPlayback(_ session: SessionView, play: Bool = true) {
        if session.done {
            cancelPlayback()
            player.stop()
            loadedAudioId = nil
            return
        }
        guard let playing = session.play else {
            guard let prompt = session.pendingPrompt else {
                player.pause()
                return
            }
            if !Settings.askAboutFigures {
                describeNo()
                return
            }
            // A describe prompt is waiting for a yes/no. Stay paused, but keep the lock screen
            // showing the question, so it can be answered from there (see NowPlaying).
            player.pause()
            if player.itemCount > 0 { player.setCurrentTitle("Describe \(prompt.label)?") }
            if play { askAloud(prompt) }
            return
        }
        guard let text = playing.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            next() // nothing to say; move on
            return
        }
        let title = playing.type == "description" ? "Describing \(playing.label ?? "")" : session.sectionTitle ?? "Section \(session.sectionIndex + 1)"
        let resume = playing.audioId == pausedAudioId
        let newSection = playing.type == "segment" && sectionGapFrom != nil && sectionGapFrom != session.sectionIndex
        sectionGapFrom = nil
        speak(
            playing.audioId,
            text,
            title: title,
            startIndex: resume ? pausedItemIndex : 0,
            startPositionMs: resume ? pausedPositionMs : 0,
            // A description is made on the spot, so it gets the live voice; the paper's own text
            // can be prepared ahead in the main one.
            voice: playing.type == "description" ? Voice.live() : Voice.current(),
            startDelayMs: newSection ? sectionGapMs : 0,
            play: play
        )
        pausedAudioId = nil
        if playing.type == "segment" { prefetchAfter(playing.audioId) }
    }

    /// Renders `text` to speech (cached per paper) and plays it, starting as soon as its first part
    /// is ready and adding the rest as they're made (see Speech.render).
    private func speak(
        _ audioId: String,
        _ text: String,
        title: String,
        startIndex: Int = 0,
        startPositionMs: Int64 = 0,
        voice: Voice? = nil,
        startDelayMs: Int64 = 0,
        play: Bool = true
    ) {
        let voice = voice ?? Voice.current()
        let dir = paperId.map(Core.ttsDir) ?? scratchDir
        let artist = paperId
        cancelPlayback()
        prefetchTask?.cancel()
        // Anything else spoken takes the summary's place, so its button goes back to Play.
        if audioId != summaryAudioId { summarySpeech = .off }
        loadedAudioId = audioId
        loadedText = text
        audioLoaded = false
        autoPlay = play
        playbackRunning = true
        playbackGeneration += 1
        let generation = playbackGeneration
        playbackTask = Task {
            defer { if generation == playbackGeneration { playbackRunning = false } }
            var items: [PlayerItem] = []
            var started = false
            // The pause counts from now, so time spent rendering is part of it.
            let startAt = Date().addingTimeInterval(Double(startDelayMs) / 1000)

            @MainActor func start(index: Int, positionMs: Int64) async throws {
                try await sleepMs(Int64(startAt.timeIntervalSinceNow * 1000))
                try Task.checkCancellation()
                player.playWhenReady = autoPlay
                player.setItems(items, index: index, positionMs: positionMs)
                player.setRate(rate)
                audioLoaded = true
                started = true
                if audioId == summaryAudioId { summarySpeech = .ready }
            }

            do {
                partLengths = try await speech.partTexts(text, voice: voice).map(\.count)
                try Task.checkCancellation()
                try await speech.render(text, dir: dir, name: audioId, voice: voice) { file in
                    try Task.checkCancellation()
                    let item = PlayerItem(url: file, mediaId: audioId, title: title, artist: artist)
                    if !started {
                        items.append(item)
                        if items.count > startIndex { try await start(index: startIndex, positionMs: startPositionMs) }
                    } else {
                        player.addItem(item)
                        // Played every part made so far before this one was ready: carry on.
                        if player.state == .ended && autoPlay {
                            player.seek(index: player.itemCount - 1, positionMs: 0)
                            player.play()
                        }
                    }
                }
                if !started && !items.isEmpty { try await start(index: items.count - 1, positionMs: 0) } // fewer parts than when paused
            } catch is CancellationError {
                return
            } catch {
                let problem = (error as? LocalizedError)?.errorDescription ?? "Couldn't speak this part"
                if audioId == summaryAudioId {
                    // Shown on the summary screen; narration stays put until that's left.
                    message = problem
                    summarySpeech = .off
                } else if interjectionState != .idle {
                    // Something spoken instead of narration: don't leave the session stuck on it.
                    message = problem
                    finishAside()
                } else {
                    reportProblem(problem)
                }
            }
        }
    }

    /// True while the loaded audio's later parts are still being rendered, so running out of audio
    /// means "wait for the next part", not "this passage is done".
    private var renderingParts: Bool { playbackRunning }

    /// Roughly how far through `audioId`'s text playback is, 0 to 1, by characters: the parts before
    /// the current one, plus how far into it the player is. Approximate -- speech doesn't run at an
    /// even rate -- but enough to keep the spoken line on screen.
    public func spokenFraction(_ audioId: String?) -> Float {
        guard let audioId, audioId == loadedAudioId, player.itemCount > 0 else { return 0 }
        // Kokoro adds parts as they're rendered, so fewer items than parts is normal. More means a
        // Gemini voice fell back to the phone voice and split differently: then treat its parts as
        // equal.
        let lengths = player.itemCount <= partLengths.count ? partLengths : [Int](repeating: 1, count: player.itemCount)
        guard !lengths.isEmpty else { return 0 }
        let index = max(0, min(player.currentIndex, lengths.count - 1))
        let duration = player.durationMs
        let within = duration > 0 ? max(0, min(1, Float(player.currentPositionMs) / Float(duration))) : 0
        let before = lengths.prefix(index).reduce(0, +)
        let total = lengths.reduce(0, +)
        return max(0, min(1, (Float(before) + Float(lengths[index]) * within) / Float(max(total, 1))))
    }

    /// Renders the next few segments in the background, so each is ready the moment the one before
    /// it ends -- a Gemini voice takes a few seconds per paragraph, the Kokoro voice longer. Waits
    /// for the current segment first, so it never slows that down.
    private func prefetchAfter(_ audioId: String) {
        guard let id = paperId, let index = narration.firstIndex(where: { $0.audioId == audioId }) else { return }
        let upcoming = narration.dropFirst(index + 1).prefix(prefetchSegments)
        let current = playbackTask
        prefetchTask?.cancel()
        prefetchTask = Task {
            await current?.value
            for next in upcoming {
                do {
                    try Task.checkCancellation()
                    try await speech.render(next.text, dir: Core.ttsDir(id), name: next.audioId)
                } catch {
                    break // best effort; each is rendered again when actually played
                }
            }
        }
    }

    private func onAudioEnded() {
        if renderingParts { return } // the next part is on its way (see speak)
        if !audioLoaded { return } // that was earlier audio, and what's meant to follow it failed
        if speakingSummary {
            summarySpeech = .off
            return
        }
        if let prompt = askedPrompt, loadedAudioId == askAudioId(prompt) { return listenForAnswer() }
        switch interjectionState {
        // An answer or something else Albert said finished on its own -- on to what's next.
        case .answered, .telling: finishAside()
        case .failed: if announceProblems { finishAside() }
        // A segment or description finished -- advance, same as tapping Next. `next` resolves
        // whatever comes next (segment, describe prompt, or the end).
        case .idle:
            guard let session = uiState.session else { return }
            if session.play?.audioId == loadedAudioId { act("next", naturalFromSection: session.sectionIndex) }
        default: break
        }
    }
}
