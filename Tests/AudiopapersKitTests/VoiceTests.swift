import XCTest
@testable import AudiopapersKit

@MainActor
final class MicPipelineTests: XCTestCase {
    private let frame = [Int16](repeating: 500, count: micFrameSamples)
    private var mic: FakeMic!
    private var detector: FakeDetector!
    private var woke = 0
    private var problems: [String] = []

    override func setUp() async throws {
        try TestWorld.start()
        mic = FakeMic()
        detector = FakeDetector()
        woke = 0
        problems = []
    }

    private func pipeline(detector: Bool = true) -> MicPipeline {
        let found = self.detector!
        return MicPipeline(
            source: mic,
            micMode: { .plain },
            createDetector: detector ? { found } : nil,
            threshold: { 0.5 },
            onWake: { [self] in woke += 1 },
            onProblem: { [self] in problems.append($0) }
        )
    }

    func testPiecesOfAnySizeBecomeFrames() {
        let pipeline = pipeline()
        pipeline.start()
        var frames: [Int] = []
        pipeline.startStreaming(fromWake: false) { frames.append($0.count) }
        mic.deliver([Int16](repeating: 1, count: 1000))
        XCTAssertEqual(frames, [])
        mic.deliver([Int16](repeating: 1, count: 1000))
        XCTAssertEqual(frames, [micFrameSamples])
        mic.deliver([Int16](repeating: 1, count: 2000))
        XCTAssertEqual(frames, [micFrameSamples, micFrameSamples, micFrameSamples])
    }

    func testTheWakeWordFiresOnceItHoldsAndWaitsToBeRearmed() async throws {
        let pipeline = pipeline()
        pipeline.start()
        detector.scores = [0.9, 0.9, 0.9, 0.9]
        for _ in 0..<4 { mic.deliver(frame) }
        try await eventually("the wake") { woke == 1 }

        pipeline.rearm()
        detector.scores = [0.9, 0.9]
        for _ in 0..<2 { mic.deliver(frame) }
        try await eventually("the second wake") { woke == 2 }
    }

    func testWhatsSaidAroundTheWakeWordGoesToTheRecognizer() async throws {
        let pipeline = pipeline()
        pipeline.start()
        detector.scores = [Float](repeating: 0, count: 8) + [0.9, 0.9]
        for _ in 0..<9 { mic.deliver(frame.map { _ in 1 }) }
        mic.deliver(frame.map { _ in 2 })
        try await eventually("the wake") { woke == 1 }
        mic.deliver(frame.map { _ in 3 }) // said while the recognizer was getting ready

        var heard: [[Int16]] = []
        pipeline.startStreaming(fromWake: true) { heard.append($0) }

        // The frame since the wake, plus a little from before it fired.
        XCTAssertEqual(heard[0].count, micFrameSamples + micSampleRate * 2 / 5)
        XCTAssertEqual(heard[0].last, 3)

        mic.deliver(frame.map { _ in 4 })
        XCTAssertEqual(heard[1].first, 4)
    }

    func testWithoutAWakeTheRecognizerGetsAMoment() {
        let pipeline = pipeline()
        pipeline.start()
        for _ in 0..<10 { mic.deliver(frame) }
        var heard: [[Int16]] = []
        pipeline.startStreaming(fromWake: false) { heard.append($0) }
        XCTAssertEqual(heard[0].count, micSampleRate / 5)
    }

    func testAPipelineWithNoDetectorStillHears() async throws {
        let pipeline = pipeline(detector: false)
        pipeline.start()
        var heard = 0
        pipeline.startStreaming(fromWake: false) { heard += $0.count }
        mic.deliver(frame)
        XCTAssertEqual(heard, micFrameSamples)
        XCTAssertEqual(woke, 0)
    }

    func testAMicThatWontOpenIsReported() async throws {
        mic.failing = true
        let pipeline = pipeline()
        pipeline.start()
        XCTAssertFalse(pipeline.isRunning)
        try await eventually("the problem") { !problems.isEmpty }
        XCTAssertEqual(problems, ["Couldn't open the microphone."])
    }

    func testStoppingLetsTheMicGo() {
        let pipeline = pipeline()
        pipeline.start()
        XCTAssertTrue(pipeline.isRunning)
        pipeline.stop()
        XCTAssertEqual(mic.stops, 1)
        XCTAssertFalse(pipeline.isRunning)
    }

    func testQuietLevelIsTheQuieterEndOfWhatsBeenHeard() {
        let pipeline = pipeline()
        pipeline.start()
        XCTAssertTrue(pipeline.quietLevelDb().isNaN)
        for _ in 0..<10 { mic.deliver(frame) }
        XCTAssertEqual(pipeline.quietLevelDb(), SpeechEndpointer.levelDb(frame), accuracy: 0.01)
    }
}

@MainActor
final class SpeechInputTests: XCTestCase {
    private var mic: FakeMic!
    private var recognizer: FakeRecognizer!
    private var input: SpeechInput!
    private var texts: [String?] = []
    private var failures: [String] = []
    private var sayAgains = 0
    private var partials: [String] = []

    override func setUp() async throws {
        try TestWorld.start()
        Settings.brokenSpeechRoutes = []
        mic = FakeMic()
        recognizer = FakeRecognizer()
        texts = []
        failures = []
        sayAgains = 0
        partials = []
        let source = mic!
        input = SpeechInput(engine: recognizer) {
            MicPipeline(source: source, micMode: { .plain }, createDetector: nil, threshold: { 1 }, onWake: {})
        }
    }

    private func listen(_ mode: ListenMode = .command, terms: [String] = []) {
        input.listen(
            mode: mode,
            terms: terms,
            fromWake: false,
            onPartial: { [self] in partials.append($0) },
            onText: { [self] in texts.append($0) },
            onFailure: { [self] in failures.append($0) },
            onSayAgain: { [self] in sayAgains += 1 }
        )
    }

    private func loud() -> [Int16] {
        (0..<micFrameSamples).map { Int16(sin(2 * Double.pi * 300 * Double($0) / Double(micSampleRate)) * 6000) }
    }

    func testPrefersTheRecognizerOnThePhoneAndPassesTheTerms() {
        listen(terms: ["Introduction"])
        XCTAssertEqual(recognizer.onDevice, [true])
        XCTAssertEqual(recognizer.terms, [["Introduction"]])
    }

    func testStartsAndStopsItsOwnMicWhenNothingIsListening() {
        listen()
        XCTAssertEqual(mic.startedModes, [.plain])
        recognizer.onFinal?("next section")
        XCTAssertEqual(texts, ["next section"])
        XCTAssertEqual(mic.stops, 1)
    }

    func testUsesAPipelineThatsAlreadyRunningAndLeavesItRunning() {
        let running = MicPipeline(source: mic, micMode: { .plain }, createDetector: nil, threshold: { 1 }, onWake: {})
        running.start()
        input.pipeline = running
        listen()
        XCTAssertEqual(mic.startedModes.count, 1)
        recognizer.onFinal?("hello")
        XCTAssertEqual(mic.stops, 0)
    }

    func testAudioReachesTheRecognizer() {
        listen()
        mic.deliver(loud())
        XCTAssertEqual(recognizer.sessions[0].audio.count, micFrameSamples)
    }

    func testPartialsAreTrimmedAndEmptyOnesDropped() {
        listen()
        recognizer.onPartial?("  next ")
        recognizer.onPartial?("   ")
        XCTAssertEqual(partials, ["next"])
    }

    func testStoppingEndsTheAudioAndWaitsForTheResult() {
        listen()
        input.stop()
        XCTAssertTrue(recognizer.sessions[0].ended)
        XCTAssertEqual(texts, [])
        recognizer.onFinal?("what I said")
        XCTAssertEqual(texts, ["what I said"])
    }

    func testCancellingDropsWhatWasHeard() {
        listen()
        input.cancel()
        XCTAssertTrue(recognizer.sessions[0].cancelled)
        recognizer.onFinal?("too late")
        XCTAssertEqual(texts, [])
    }

    func testSilenceEndsInNothing() async throws {
        listen()
        // YES, there's a floor to find: command mode waits 4 s, 50 frames.
        for _ in 0..<60 { mic.deliver([Int16](repeating: 0, count: micFrameSamples)) }
        try await eventually("it to give up") { !texts.isEmpty }
        XCTAssertEqual(texts, [nil])
        XCTAssertTrue(recognizer.sessions[0].cancelled)
    }

    func testAFailureFallsBackToTheServerWithWhatWasAlreadySaid() {
        listen()
        mic.deliver(loud())
        recognizer.onFailure?(.other("on-device model missing"))
        XCTAssertEqual(recognizer.onDevice, [true, false])
        XCTAssertEqual(recognizer.sessions[1].audio.count, micFrameSamples)
        XCTAssertTrue(recognizer.sessions[1].ended)
        recognizer.onFinal?("recovered")
        XCTAssertEqual(texts, ["recovered"])
    }

    func testAFallbackWithNothingSaidYetStillListens() {
        listen()
        recognizer.onFailure?(.other("on-device model missing"))
        XCTAssertFalse(recognizer.sessions[1].ended)
        mic.deliver(loud())
        XCTAssertEqual(recognizer.sessions[1].audio.count, micFrameSamples)
    }

    func testAWayOfHearingThatKeepsFailingIsGivenUpOn() {
        for _ in 0..<3 {
            listen()
            recognizer.onFailure?(.other("broken"))
            recognizer.onFinal?("from the server")
        }
        XCTAssertEqual(Settings.brokenSpeechRoutes, ["DEVICE"])
        listen()
        XCTAssertEqual(recognizer.onDevice.last, false)

        input.forgetFailures()
        input.cancel()
        listen()
        XCTAssertEqual(recognizer.onDevice.last, true)
    }

    func testHeardButLostAsksForItAgain() {
        recognizer.supportsOnDevice = false
        listen()
        for _ in 0..<5 { mic.deliver([Int16](repeating: 0, count: micFrameSamples)) }
        for _ in 0..<5 { mic.deliver(loud()) }
        recognizer.onFinal?("")
        XCTAssertEqual(sayAgains, 1)
        XCTAssertEqual(texts, [])
    }

    func testNoSpeechFromTheRecognizerWithNothingHeardIsNothing() {
        listen()
        recognizer.onFailure?(.noSpeech)
        XCTAssertEqual(texts, [nil])
    }

    func testPermissionIsAFailureWithAMessage() {
        listen()
        recognizer.onFailure?(.permission)
        XCTAssertEqual(failures, ["Microphone and speech recognition permission are needed for that."])
    }

    func testAMissingLanguageSaysHowToGetIt() {
        recognizer.supportsOnDevice = false
        listen()
        recognizer.onFailure?(.languageMissing)
        XCTAssertTrue(failures[0].contains("doesn't have English yet"))
        XCTAssertEqual(Settings.brokenSpeechRoutes, [])
    }

    func testNoRecognizerAtAllIsReported() {
        recognizer.isAvailable = false
        recognizer.supportsOnDevice = false
        listen()
        XCTAssertEqual(failures, ["Speech recognition isn't available on this phone."])
    }

    // MARK: Listening until "over"

    private func listenUntilOver(onPause: ((String) -> Void)? = nil) {
        input.listen(
            mode: .question,
            terms: [],
            fromWake: false,
            untilOver: onPause == nil,
            onPause: onPause,
            onPartial: { [self] in partials.append($0) },
            onText: { [self] in texts.append($0) },
            onFailure: { [self] in failures.append($0) },
            onSayAgain: { [self] in sayAgains += 1 }
        )
    }

    private func quiet() -> [Int16] { [Int16](repeating: 0, count: micFrameSamples) }

    func testUntilOverCarriesOnWhenTheRecognizerStopsAtAPause() async throws {
        listenUntilOver()
        recognizer.onFinal?("what does the residual")
        XCTAssertEqual(texts, [])
        try await eventually("a new session") { recognizer.sessions.count == 2 }
        recognizer.onPartial?("block")
        XCTAssertEqual(partials.last, "what does the residual block")
        recognizer.onFinal?("block do over")
        XCTAssertEqual(texts, ["what does the residual block do"])
    }

    func testOverHeardJustBeforeAPauseFinishesIt() async throws {
        listenUntilOver()
        recognizer.onPartial?("what is dropout over")
        // Some quiet first, which the endpointer takes its noise floor from.
        for _ in 0..<3 { mic.deliver(quiet()) }
        for _ in 0..<5 { mic.deliver(loud()) }
        for _ in 0..<12 { mic.deliver(quiet()) }
        try await eventually("it to finish") { recognizer.sessions[0].ended }
        recognizer.onFinal?("what is dropout over")
        XCTAssertEqual(texts, ["what is dropout"])
    }

    func testAPauseWithoutOverKeepsListening() async throws {
        listenUntilOver()
        recognizer.onPartial?("what is dropout")
        // Some quiet first, which the endpointer takes its noise floor from.
        for _ in 0..<3 { mic.deliver(quiet()) }
        for _ in 0..<5 { mic.deliver(loud()) }
        for _ in 0..<12 { mic.deliver(quiet()) }
        try await sleepMs(100)
        XCTAssertFalse(recognizer.sessions[0].ended)
        XCTAssertEqual(texts, [])
        recognizer.onPartial?("what is dropout for over")
        try await eventually("it to finish") { recognizer.sessions[0].ended }
    }

    func testAPauseAsksAndCanCarryOnUntilOver() async throws {
        var asked: [String] = []
        listenUntilOver { asked.append($0) }
        recognizer.onFinal?("what is")
        XCTAssertEqual(asked, ["what is"])
        input.keepUntilOver()
        try await eventually("a new session") { recognizer.sessions.count == 2 }
        recognizer.onFinal?("dropout over")
        XCTAssertEqual(texts, ["what is dropout"])
    }

    func testAPauseAsksAndCanFinishThere() async throws {
        listenUntilOver { [self] _ in input.stop() }
        recognizer.onFinal?("next section over")
        try await eventually("it to finish") { !texts.isEmpty }
        // Not listening for "over", so it's left as it was said.
        XCTAssertEqual(texts, ["next section over"])
    }

    func testFinishingEarlyKeepsWhatEarlierStretchesHeard() async throws {
        listenUntilOver()
        recognizer.onFinal?("what does figure three")
        try await eventually("a new session") { recognizer.sessions.count == 2 }
        input.stop()
        XCTAssertEqual(texts, ["what does figure three"])
        XCTAssertTrue(recognizer.sessions[1].cancelled)
    }

    func testWhatsSaidBetweenSessionsGoesToTheNextOne() async throws {
        listenUntilOver()
        mic.deliver(quiet())
        recognizer.onFinal?("what does the")
        // Said once that session had finished, before the next one started.
        mic.deliver(loud())
        try await eventually("a new session") { recognizer.sessions.count == 2 }
        XCTAssertEqual(recognizer.sessions[0].audio, quiet())
        XCTAssertEqual(recognizer.sessions[1].audio, loud())
        mic.deliver(quiet())
        XCTAssertEqual(recognizer.sessions[1].audio, loud() + quiet())
    }

    func testTheRecognizerStoppingWhileStillTalkingIsntAPause() async throws {
        var asked: [String] = []
        listenUntilOver { asked.append($0) }
        for _ in 0..<3 { mic.deliver(quiet()) }
        for _ in 0..<5 { mic.deliver(loud()) }
        recognizer.onFinal?("what does the")
        XCTAssertEqual(asked, [])
        try await eventually("a new session") { recognizer.sessions.count == 2 }
        for _ in 0..<5 { mic.deliver(loud()) }
        // A question's pause is 1.5 s, 19 frames.
        for _ in 0..<25 { mic.deliver(quiet()) }
        try await eventually("the pause") { asked == ["what does the"] }
    }

    func testWhatTheRecognizerHeardBeforeTheMicCountsWhenTheMicHearsNothing() async throws {
        listen()
        // All said in what came before listening began, so the mic only hears quiet after it.
        recognizer.onPartial?("next section")
        for _ in 0..<60 { mic.deliver(quiet()) }
        try await eventually("it to finish") { recognizer.sessions[0].ended }
        recognizer.onFinal?("next section")
        XCTAssertEqual(texts, ["next section"])
    }
}

@MainActor
final class VoiceControllerTests: XCTestCase {
    private var player: FakePlayer!
    private var phone: FakePhoneVoice!
    private var mic: FakeMic!
    private var detector: FakeDetector!
    private var recognizer: FakeRecognizer!
    private var engine: ReadingEngine!
    private var voice: VoiceController!
    private var navigator: Navigator!
    private var earcons: FakeEarcons!
    private var notifier: FakeNotifier!
    private var jobs: BackgroundJobs!
    private var micAllowed = true

    override func setUp() async throws {
        try TestWorld.start()
        Settings.geminiKey = nil
        Settings.heyAlbert = true
        // Most of these are about what's done with what was heard; see the "over" tests below.
        Settings.sayOver = false
        Settings.askAboutFigures = true
        Settings.voiceEngine = .phone
        Settings.liveVoiceEngine = .phone
        Settings.brokenSpeechRoutes = []
        micAllowed = true
        player = FakePlayer()
        phone = FakePhoneVoice()
        mic = FakeMic()
        detector = FakeDetector()
        recognizer = FakeRecognizer()
        navigator = Navigator()
        earcons = FakeEarcons()
        notifier = FakeNotifier()
        let source = mic!
        let speech = Speech(phone: phone, kokoro: FakeKokoro())
        let input = SpeechInput(engine: recognizer) {
            MicPipeline(source: source, micMode: { .plain }, createDetector: nil, threshold: { 1 }, onWake: {})
        }
        engine = ReadingEngine(player: player, speech: speech, speechInput: input, micAllowed: { [self] in micAllowed }, scratchDir: TestWorld.root.appendingPathComponent("albert-\(UUID().uuidString)"))
        jobs = BackgroundJobs(speech: speech, notifier: notifier, runner: FakeRunner())
        let found = detector!
        voice = VoiceController(
            engine: engine,
            speechInput: input,
            navigator: navigator,
            earcons: earcons,
            notifier: notifier,
            jobs: jobs,
            micAllowed: { [self] in micAllowed },
            makeHandsFreePipeline: { onWake, onProblem in
                MicPipeline(source: source, micMode: { .plain }, createDetector: { found }, threshold: { 0.5 }, onWake: onWake, onProblem: onProblem)
            }
        )
        voice.onAppVisible(true)
    }

    private func openPaper(figures: Bool = false) async throws -> String {
        let id = try TestWorld.addPaper(figures: figures)
        engine.open(id)
        try await eventually("narration") { player.isPlaying }
        return id
    }

    /// As if the wake word was heard, and then this was said.
    private func say(_ text: String) async throws {
        voice.pushToTalk()
        recognizer.onFinal?(text)
    }

    func testListensOnlyWhileAPaperIsOpen() async throws {
        XCTAssertFalse(voice.handsFree)
        XCTAssertEqual(voice.state, .off)
        let id = try await openPaper()
        XCTAssertTrue(voice.handsFree)
        XCTAssertEqual(voice.state, .waiting)
        XCTAssertEqual(mic.startedModes.count, 1)
        engine.close(id)
        XCTAssertFalse(voice.handsFree)
        XCTAssertEqual(voice.state, .off)
        XCTAssertEqual(mic.stops, 1)
    }

    func testDoesntListenWithoutTheSettingOrTheMicOrTheScreen() async throws {
        Settings.heyAlbert = false
        let id = try await openPaper()
        XCTAssertFalse(voice.handsFree)
        engine.close(id)

        Settings.heyAlbert = true
        micAllowed = false
        let second = try await openPaper()
        XCTAssertFalse(voice.handsFree)
        engine.close(second)

        micAllowed = true
        voice.onAppVisible(false)
        _ = try await openPaper()
        XCTAssertFalse(voice.handsFree)
        voice.onAppVisible(true)
        XCTAssertTrue(voice.handsFree)
    }

    func testHeyAlbertInterruptsListensThenCarriesOutACommand() async throws {
        _ = try await openPaper()
        detector.scores = [0.9, 0.9]
        let frame = [Int16](repeating: 100, count: micFrameSamples)
        mic.deliver(frame)
        mic.deliver(frame)
        try await eventually("it to hear the wake word") { voice.state.isHearing }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(earcons.played, ["listening"])
        XCTAssertEqual(engine.interjectionState, .listening)

        recognizer.onPartial?("next")
        XCTAssertEqual(voice.state, .hearing(words: "next"))
        recognizer.onFinal?("next section")
        try await eventually("it to move") { player.currentId == "seg_1_0" }
        XCTAssertEqual(voice.heard, "next section")
        XCTAssertEqual(voice.state, .waiting)
        XCTAssertEqual(engine.interjectionState, .idle)
    }

    func testAPaperThatSaysAlbertDoesntCount() async throws {
        let id = try TestWorld.addPaper()
        let text = Core.paperDir(id).appendingPathComponent("extracted/text.json")
        let original = try String(contentsOf: text, encoding: .utf8)
        try original.replacingOccurrences(of: "1 Introduction", with: "1 ALBERT").write(to: text, atomically: true, encoding: .utf8)
        engine.open(id)
        try await eventually("narration") { player.isPlaying }
        XCTAssertTrue(engine.narrationSaysAlbert)
        voice.onWake()
        XCTAssertEqual(voice.state, .waiting)
        XCTAssertTrue(player.isPlaying)
    }

    func testPauseAndResumeByVoice() async throws {
        _ = try await openPaper()
        try await say("pause")
        try await eventually("it to pause") { engine.interjectionState == .idle && !player.isPlaying && player.currentId == "seg_0_0" }
        try await say("resume")
        try await eventually("it to play") { player.isPlaying }
        XCTAssertEqual(earcons.played.filter { $0 == "done" }.count, 2)
    }

    func testSpeedByVoice() async throws {
        engine.setRate(1)
        _ = try await openPaper()
        try await say("faster")
        try await eventually("it to speed up") { engine.rate == 1.25 }
        try await eventually("narration back") { player.isPlaying }
        engine.setRate(1)
    }

    func testNothingSaidPutsThingsBackAsTheyWere() async throws {
        _ = try await openPaper()
        player.currentPositionMs = 1_500
        voice.pushToTalk()
        XCTAssertFalse(player.isPlaying)
        recognizer.onFinal?(nil)
        try await eventually("narration back") { player.isPlaying }
        XCTAssertEqual(player.currentPositionMs, 1_500)
        XCTAssertEqual(voice.state, .waiting)
    }

    func testPressingTheButtonWhileHearingMeansThatsAll() async throws {
        _ = try await openPaper()
        voice.pushToTalk()
        voice.pushToTalk()
        XCTAssertTrue(recognizer.sessions[0].ended)
    }

    func testANoteSpokenInOneGoIsSaved() async throws {
        let id = try await openPaper()
        try await say("note that the baseline looks wrong")
        try await eventually("Albert to answer") { player.currentId?.hasPrefix("say_") == true }
        XCTAssertEqual(phone.rendered.last, "Noted.")
        let removed = try await Core.deleteLastNote(id)
        XCTAssertEqual(removed?.text, "the baseline looks wrong")
    }

    func testTakingANoteAsksThenListens() async throws {
        let id = try await openPaper()
        try await say("take a note")
        try await eventually("Albert to answer") { player.currentId?.hasPrefix("say_") == true }
        XCTAssertEqual(phone.rendered.last, "Go ahead.")
        player.finishItem()
        try await eventually("it to listen") { voice.state.isHearing }
        recognizer.onFinal?("check this")
        try await eventually("it to be saved") { phone.rendered.last == "Noted." }
        let removed = try await Core.deleteLastNote(id)
        XCTAssertEqual(removed?.text, "check this")
    }

    func testTheNextPaperOpensByName() async throws {
        let other = try TestWorld.addPaper("kalman-filters-\(UUID().uuidString.prefix(4).lowercased())")
        _ = try await openPaper()
        try await say("open \(other)")
        try await eventually("it to open") { engine.paperId == other }
        XCTAssertEqual(navigator.request, .reader(other))
    }

    func testScreensThatNeedTheScreenSaySoWhenItsOff() async throws {
        _ = try await openPaper()
        voice.onAppVisible(false)
        try await say("open the pdf")
        try await eventually("Albert to say so") { phone.rendered.last == "The PDF needs the screen. It's there when you open the app." }
        XCTAssertNil(navigator.request)

        player.finishItem()
        voice.onAppVisible(true)
        try await say("open the pdf")
        try await eventually("it to go there") { navigator.request != nil }
        if case .pdf? = navigator.request {} else { XCTFail("Should have gone to the PDF") }
    }

    func testRemovingAPaperAsksFirst() async throws {
        let id = try await openPaper()
        try await say("remove this paper")
        try await eventually("it to ask") { phone.rendered.last == "Remove this paper and everything saved for it? Say yes or no." && player.currentId?.hasPrefix("say_") == true }
        XCTAssertEqual(voice.state, .confirming)
        player.finishItem()
        try await eventually("it to listen for the answer") { recognizer.sessions.count == 2 }
        recognizer.onFinal?("no")
        try await eventually("it to leave it alone") { phone.rendered.last == "Okay, leaving it as it is." && player.currentId?.hasPrefix("say_") == true }
        let detail = try await Core.paperDetail(id)
        XCTAssertEqual(detail.paperId, id)
        player.finishItem()
        try await eventually("narration back") { player.currentId == "seg_0_0" && player.isPlaying }

        try await say("remove this paper")
        try await eventually("it to ask again") { voice.state == .confirming && player.currentId?.hasPrefix("say_") == true }
        player.finishItem()
        try await eventually("it to listen for the answer") { recognizer.sessions.count == 4 }
        recognizer.onFinal?("yes")
        try await eventually("it to be gone") { navigator.request == .home }
        XCTAssertNil(engine.paperId)
    }

    func testUnknownCommandsWithNoKeySaySo() async throws {
        _ = try await openPaper()
        try await say("flibbertigibbet wobble")
        try await eventually("Albert to say so") { phone.rendered.last == "I only know the built-in commands without a Gemini key, and that wasn't one." }
    }

    func testCommandsThatNeedAPaperSaySoWithoutOne() async throws {
        try await say("next section")
        try await eventually("Albert to say so") { phone.rendered.last == "No paper is open. You can say open, and the paper's name." }
    }

    func testStopListeningMutesUntilTheButtonIsPressed() async throws {
        _ = try await openPaper()
        try await say("stop listening")
        try await eventually("it to stop") { !voice.handsFree }
        XCTAssertEqual(mic.stops, 1)
        player.finishItem()
        voice.pushToTalk()
        XCTAssertTrue(voice.handsFree)
    }

    func testSpeechDuringAFigurePromptIsTreatedAsACommand() async throws {
        _ = try await openPaper(figures: true)
        player.finishItem()
        try await eventually("the paragraph") { player.currentId == "seg_0_1" }
        player.finishItem()
        try await eventually("the question") { player.currentId == "ask_figure_1" }
        player.finishItem()
        XCTAssertTrue(engine.listeningForAnswer)
        recognizer.onFinal?("next section")
        try await eventually("it to move") { player.currentId == "seg_1_0" }
    }

    func testARequestToPrepareAudioStartsTheJob() async throws {
        let id = try await openPaper()
        try await say("prepare the audio")
        try await eventually("it to finish") { notifier.sent.contains { $0.title == "Audio ready" } }
        XCTAssertEqual(OfflineAudio.readyVoice(id), "phone")
    }

    func testActAsIfHeardRunsACommandWithNoMicrophone() async throws {
        _ = try await openPaper()
        voice.actAsIfHeard("next section")
        try await eventually("it to move") { player.currentId == "seg_1_0" }
    }

    // MARK: Saying "over", and waiting after an answer

    func testWithOverOnACommandStillHappensAtThePause() async throws {
        Settings.sayOver = true
        _ = try await openPaper()
        try await say("next section")
        try await eventually("it to move") { player.currentId == "seg_1_0" }
        XCTAssertFalse(earcons.played.contains("stillListening"))
    }

    func testWithOverOnANoteWaitsForOver() async throws {
        Settings.sayOver = true
        let id = try await openPaper()
        try await say("note that the baseline")
        try await eventually("it to keep listening") { voice.state.doneHint != nil }
        XCTAssertEqual(voice.state.doneHint, "Say \"over\" when you're done with your note.")
        XCTAssertEqual(earcons.played.last, "stillListening")
        try await eventually("a new session") { recognizer.sessions.count == 2 }
        recognizer.onFinal?("looks wrong over")
        try await eventually("it to be saved") { phone.rendered.last == "Noted." }
        let removed = try await Core.deleteLastNote(id)
        XCTAssertEqual(removed?.text, "the baseline looks wrong")
    }

    func testWithOverOnDictationWaitsForOver() async throws {
        Settings.sayOver = true
        let id = try await openPaper()
        try await say("take a note")
        try await eventually("Albert to answer") { player.currentId?.hasPrefix("say_") == true }
        XCTAssertEqual(phone.rendered.last, "Go ahead. Say over when you're done.")
        player.finishItem()
        try await eventually("it to listen") { voice.state.isHearing }
        XCTAssertEqual(voice.state.doneHint, "Say \"over\" when you're done with your note.")
        recognizer.onFinal?("check the")
        try await eventually("a new session") { recognizer.sessions.count == 3 }
        recognizer.onFinal?("second table over")
        try await eventually("it to be saved") { phone.rendered.last == "Noted." }
        let removed = try await Core.deleteLastNote(id)
        XCTAssertEqual(removed?.text, "check the second table")
    }

    func testAfterARecapOrSummaryContinueCarriesOnReading() async throws {
        _ = try await openPaper()
        engine.tell("Recap", "So far, residual networks.", voice: .phone, waits: true)
        try await eventually("Albert to speak") { player.currentId?.hasPrefix("say_") == true }
        player.finishItem()
        try await eventually("it to wait") { engine.isWaitingAfterAside }
        XCTAssertFalse(player.isPlaying)
        try await say("continue")
        try await eventually("narration back") { player.currentId == "seg_0_0" && player.isPlaying }
        XCTAssertEqual(engine.interjectionState, .idle)
    }

    func testWhileWaitingNothingSaidLeavesItWaiting() async throws {
        _ = try await openPaper()
        engine.tell("Recap", "So far, residual networks.", voice: .phone, waits: true)
        try await eventually("Albert to speak") { player.currentId?.hasPrefix("say_") == true }
        player.finishItem()
        try await eventually("it to wait") { engine.isWaitingAfterAside }
        let spoken = phone.rendered.count
        voice.pushToTalk()
        recognizer.onFinal?(nil)
        try await eventually("it to wait again") { engine.isWaitingAfterAside }
        XCTAssertEqual(phone.rendered.count, spoken)
        XCTAssertFalse(player.isPlaying)
    }

    func testWithOverOnHeyAlbertThenAPauseThenContinueCarriesOnReading() async throws {
        Settings.sayOver = true
        _ = try await openPaper()
        engine.tell("Recap", "So far, residual networks.", voice: .phone, waits: true)
        try await eventually("Albert to speak") { player.currentId?.hasPrefix("say_") == true }
        player.finishItem()
        try await eventually("it to wait") { engine.isWaitingAfterAside }
        // The recognizer stops after the wake words, then hears the rest in its next session.
        try await say("hey Albert")
        try await eventually("a new session") { recognizer.sessions.count == 2 }
        XCTAssertTrue(voice.state.isHearing)
        recognizer.onFinal?("continue")
        try await eventually("narration back") { player.currentId == "seg_0_0" && player.isPlaying }
        XCTAssertEqual(engine.interjectionState, .idle)
    }

    func testWithOverOnAQuestionStartingWithWhatWaitsAtThePause() async throws {
        Settings.sayOver = true
        _ = try await openPaper()
        try await say("what")
        try await eventually("a new session") { recognizer.sessions.count == 2 }
        XCTAssertNil(voice.state.doneHint)
        recognizer.onFinal?("is the main contribution")
        try await eventually("it to wait for over") { voice.state.doneHint != nil }
        XCTAssertEqual(voice.state.doneHint, "Say \"over\" when you're done asking your question.")
    }

    func testWithOverOnSayingOnlyOverGoesBackToWaitingForHeyAlbert() async throws {
        Settings.sayOver = true
        _ = try await openPaper()
        engine.tell("Recap", "So far, residual networks.", voice: .phone, waits: true)
        try await eventually("Albert to speak") { player.currentId?.hasPrefix("say_") == true }
        player.finishItem()
        try await eventually("it to wait") { engine.isWaitingAfterAside }
        // Taken for the start of a question at the pause, but it's also the end of one.
        try await say("over")
        try await eventually("Hey Albert to work again") { voice.state == .waiting }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(voice.state, .waiting)
    }
}

@MainActor
final class BackgroundJobsTests: XCTestCase {
    private var phone: FakePhoneVoice!
    private var notifier: FakeNotifier!
    private var runner: FakeRunner!
    private var jobs: BackgroundJobs!

    override func setUp() async throws {
        try TestWorld.start()
        Settings.voiceEngine = .phone
        Settings.defaults.removeObject(forKey: "pending_audio_downloads")
        phone = FakePhoneVoice()
        notifier = FakeNotifier()
        runner = FakeRunner()
        jobs = BackgroundJobs(speech: Speech(phone: phone, kokoro: FakeKokoro()), notifier: notifier, runner: runner)
    }

    func testDownloadsEveryParagraphThenSaysSo() async throws {
        let id = try TestWorld.addPaper()
        jobs.downloadAudio(id)
        try await eventually("it to finish") { OfflineAudio.readyVoice(id) != nil }
        try await settled()
        XCTAssertEqual(OfflineAudio.readyVoice(id), "phone")
        XCTAssertNil(jobs.audioJobs[id])
        XCTAssertEqual(phone.rendered.count, 5)
        XCTAssertEqual(notifier.sent.last?.title, "Audio ready")
        XCTAssertEqual(runner.leases.first?.ended, true)
    }

    func testAFailureSaysHowFarItGot() async throws {
        phone.failing = true
        let id = try TestWorld.addPaper()
        jobs.downloadAudio(id)
        try await eventually("it to stop") { if case .failed = jobs.audioJobs[id] { return true } else { return false } }
        XCTAssertEqual(jobs.audioJobs[id], .failed("Saved 0 of 5 paragraphs, then stopped. Text-to-speech failed"))
        XCTAssertEqual(notifier.sent.last?.title, "Audio for \"\(id)\" stopped")
    }

    func testOutOfBackgroundTimeItPicksUpNextTime() async throws {
        let id = try TestWorld.addPaper()
        jobs.downloadAudio(id)
        runner.expiries[0]()
        try await settled()
        XCTAssertNil(OfflineAudio.readyVoice(id))

        // The app's been stopped and opened again.
        let reopened = BackgroundJobs(speech: Speech(phone: phone, kokoro: FakeKokoro()), notifier: notifier, runner: runner)
        reopened.resumePending()
        try await eventually("it to finish") { OfflineAudio.readyVoice(id) != nil }
    }

    func testCancellingForgetsIt() async throws {
        let id = try TestWorld.addPaper()
        jobs.downloadAudio(id)
        jobs.cancelAudio(id)
        XCTAssertNil(jobs.audioJobs[id])
        let reopened = BackgroundJobs(speech: Speech(phone: phone, kokoro: FakeKokoro()), notifier: notifier, runner: runner)
        reopened.resumePending()
        XCTAssertNil(reopened.audioJobs[id])
    }

    func testIngestWithNoKeyFailsAndDeletesItsCopy() async throws {
        Settings.geminiKey = nil
        let pdf = TestWorld.root.appendingPathComponent("\(UUID().uuidString).pdf")
        ensureDirectory(TestWorld.root)
        try Data("%PDF".utf8).write(to: pdf)
        jobs.ingest(pdf: pdf, fileName: "paper.pdf", downloadAudio: false) { _ in XCTFail("Shouldn't succeed") }
        try await eventually("it to fail") { if case .failed = jobs.ingestState { return true } else { return false } }
        XCTAssertEqual(jobs.ingestState, .failed("Add your free Gemini API key in Settings first."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertEqual(notifier.sent.last?.title, "Couldn't add paper.pdf")
        jobs.dismissIngestError()
        XCTAssertEqual(jobs.ingestState, .idle)
    }
}

@MainActor
final class ViewModelTests: XCTestCase {
    private func makeHome() -> HomeModel {
        HomeModel(jobs: BackgroundJobs(speech: Speech(phone: FakePhoneVoice(), kokoro: FakeKokoro()), notifier: FakeNotifier(), runner: FakeRunner()))
    }

    override func setUp() async throws {
        try TestWorld.start()
        Settings.voiceEngine = .phone
    }

    func testHomeListsPapersAndActsOnThem() async throws {
        let id = try TestWorld.addPaper()
        let home = makeHome()
        home.refresh()
        func listed() -> [PaperSummary] {
            if case .loaded(let papers) = home.papers { return papers }
            return []
        }
        try await eventually("the list") { listed().contains { $0.id == id } }

        home.markPaperRead(id)
        try await eventually("it to be marked") { listed().first { $0.id == id }?.done == true }

        home.clearPaper(id)
        try await eventually("it to be cleared") { listed().first { $0.id == id }?.done == false }

        let renamed = "renamed-\(UUID().uuidString.prefix(6).lowercased())"
        home.renamePaper(id, renamed)
        try await eventually("it to be renamed") { listed().contains { $0.id == renamed } }

        home.removePaper(renamed)
        try await eventually("it to be gone") { !listed().contains { $0.id == renamed } }
    }

    func testAFailedActionIsShown() async throws {
        let home = makeHome()
        home.removePaper("no-such-paper")
        try await eventually("the failure") { home.actionFailure != nil }
        home.dismissActionFailure()
        XCTAssertNil(home.actionFailure)
    }

    func testHomeKnowsAboutTheKey() async throws {
        Settings.geminiKey = "a-key"
        let home = makeHome()
        home.refresh()
        XCTAssertTrue(home.hasKey)
        Settings.geminiKey = nil
        home.refresh()
        XCTAssertFalse(home.hasKey)
    }

    func testAudioStatusCombinesJobsAndWhatsSaved() async throws {
        let id = try TestWorld.addPaper()
        let home = makeHome()
        home.refresh()
        try await settled()
        XCTAssertNil(home.audioStatus(id))
        OfflineAudio.markReady(id, voiceLabel: "phone", segments: 5)
        home.refresh()
        try await eventually("it to be ready") { home.audioStatus(id) == .ready }
    }

    func testAKeyIsCheckedBeforeBeingSaved() async throws {
        Settings.geminiKey = nil
        let model = KeySetupModel()
        model.saveAndCheck(key: "", model: "")
        XCTAssertEqual(model.state, .failed("Paste your Gemini API key first."))
        XCTAssertNil(Settings.geminiKey)
    }

    func testSummaryWithNothingWrittenOffersToGenerate() async throws {
        let id = try TestWorld.addPaper()
        let engine = ReadingEngine(player: FakePlayer(), speech: Speech(phone: FakePhoneVoice(), kokoro: FakeKokoro()), speechInput: FakeListener(), micAllowed: { true }, scratchDir: TestWorld.root)
        let model = SummaryModel(paperId: id, engine: engine)
        try await eventually("it to load") { model.state == .notGenerated }
        XCTAssertFalse(model.canSpeak)
        Settings.geminiKey = nil
        model.generate()
        try await eventually("it to say why not") { if case .error = model.state { return true } else { return false } }
    }

    func testAnExistingSummaryIsBlocksAndSpeech() async throws {
        let id = try TestWorld.addPaper()
        try "# Title\n\n## Summary\n\nIt works.\n".write(to: Core.paperDir(id).appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let engine = ReadingEngine(player: FakePlayer(), speech: Speech(phone: FakePhoneVoice(), kokoro: FakeKokoro()), speechInput: FakeListener(), micAllowed: { true }, scratchDir: TestWorld.root)
        let model = SummaryModel(paperId: id, engine: engine)
        try await eventually("it to load") { if case .ready = model.state { return true } else { return false } }
        if case .ready(let blocks, let speech) = model.state {
            XCTAssertEqual(blocks.first?.type, "heading")
            XCTAssertTrue(speech.hasPrefix("Title."))
        }
    }
}
