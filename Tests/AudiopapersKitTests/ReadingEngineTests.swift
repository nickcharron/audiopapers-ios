import XCTest
@testable import AudiopapersKit

@MainActor
final class ReadingEngineTests: XCTestCase {
    private var player: FakePlayer!
    private var phone: FakePhoneVoice!
    private var listener: FakeListener!
    private var engine: ReadingEngine!

    override func setUp() async throws {
        try TestWorld.start()
        Settings.defaults.removePersistentDomain(forName: "unused")
        Settings.geminiKey = nil
        Settings.askAboutFigures = true
        Settings.voiceEngine = .phone
        Settings.liveVoiceEngine = .phone
        Settings.summaryVoiceEngine = .phone
        player = FakePlayer()
        phone = FakePhoneVoice()
        listener = FakeListener()
        engine = ReadingEngine(
            player: player,
            speech: Speech(phone: phone, kokoro: FakeKokoro()),
            speechInput: listener,
            micAllowed: { true },
            scratchDir: TestWorld.root.appendingPathComponent("albert-\(UUID().uuidString)")
        )
    }

    private func openPaper(figures: Bool = false) async throws -> String {
        let id = try TestWorld.addPaper(figures: figures)
        engine.open(id)
        try await eventually("the first paragraph to play") { player.isPlaying }
        return id
    }

    func testNarrationPlaysFromTheStartOfTheFirstSection() async throws {
        _ = try await openPaper()
        XCTAssertEqual(player.currentId, "seg_0_0")
        XCTAssertEqual(phone.rendered.first, "1 Introduction") // headings are read out too
        XCTAssertEqual(engine.uiState.session?.sectionTitle, "1 Introduction")
        XCTAssertEqual(engine.uiState.session?.totalSections, 2)
    }

    func testAdvancesParagraphByParagraphWhenAudioEnds() async throws {
        _ = try await openPaper()
        player.finishItem()
        try await eventually("the second paragraph") { player.currentId == "seg_0_1" && player.isPlaying }
        XCTAssertEqual(engine.uiState.session?.segmentIndex, 1)
    }

    func testANewSectionStartsAfterAPauseWhenItGetsThereByItself() async throws {
        _ = try await openPaper()
        player.finishItem()
        try await eventually("the first paragraph") { player.currentId == "seg_0_1" && player.isPlaying }
        player.finishItem()
        try await eventually("the second paragraph") { player.currentId == "seg_0_2" && player.isPlaying }
        let before = Date()
        player.finishItem()
        try await eventually("the next section") { player.currentId == "seg_1_0" && player.isPlaying }
        XCTAssertGreaterThan(Date().timeIntervalSince(before), 1.5)
    }

    func testTappingToTheNextSectionStartsRightAway() async throws {
        _ = try await openPaper()
        let before = Date()
        engine.nextSection()
        try await eventually("the next section") { player.currentId == "seg_1_0" }
        XCTAssertLessThan(Date().timeIntervalSince(before), 1.5)
    }

    func testReachingTheEndFinishesAndGoingBackReturnsToIt() async throws {
        _ = try await openPaper()
        engine.nextSection()
        try await eventually("the last section") { player.currentId == "seg_1_0" }
        engine.nextSection()
        try await eventually("the end") { engine.uiState.session?.done == true }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.itemCount, 0)

        engine.previousParagraph()
        try await eventually("the last paragraph") { player.currentId == "seg_1_1" && player.isPlaying }
        XCTAssertEqual(engine.uiState.session?.done, false)
    }

    func testPausingHoldsAPlaceAndPlayingCarriesOn() async throws {
        _ = try await openPaper()
        engine.togglePlayPause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(engine.isPlaying)
        engine.togglePlayPause()
        XCTAssertTrue(player.isPlaying)
    }

    func testAFailedVoiceIsReportedWithoutEndingTheSession() async throws {
        phone.failing = true
        let id = try TestWorld.addPaper()
        engine.open(id)
        try await eventually("the problem") { engine.message != nil }
        XCTAssertEqual(engine.message, "Text-to-speech failed")
        XCTAssertNotNil(engine.uiState.session)
    }

    func testAudioIsCachedAndNotRenderedTwice() async throws {
        _ = try await openPaper()
        let count = phone.rendered.filter { $0 == "1 Introduction" }.count
        engine.restartParagraph()
        try await settled()
        XCTAssertEqual(phone.rendered.filter { $0 == "1 Introduction" }.count, count)
    }

    func testTheNextParagraphsAreRenderedAhead() async throws {
        _ = try await openPaper()
        try await eventually("the next two to be rendered") { phone.rendered.contains("We study snow.") && phone.rendered.contains("It works well.") }
    }

    func testRateIsKeptBetweenSessions() async throws {
        engine.setRate(1.5)
        XCTAssertEqual(Settings.playbackRate, 1.5)
        _ = try await openPaper()
        XCTAssertEqual(player.rate, 1.5)
        XCTAssertEqual(engine.rate, 1.5)
        engine.setRate(1)
    }

    // MARK: - Figure prompts

    /// The heading, then the paragraph that mentions the figure.
    private func playToThePrompt() async throws {
        _ = try await openPaper(figures: true)
        player.finishItem()
        try await eventually("the paragraph") { player.currentId == "seg_0_1" }
        player.finishItem()
        try await eventually("the prompt") { engine.uiState.session?.pendingPrompt != nil }
    }

    func testAFigureMentionAsksAloudAndListensForAnAnswer() async throws {
        try await playToThePrompt()
        XCTAssertEqual(engine.uiState.session?.pendingPrompt?.label, "Figure 1")
        try await eventually("the question to be read out") { player.currentId == "ask_figure_1" }
        XCTAssertEqual(phone.rendered.last, "Describe Figure 1, yes or no?")

        player.finishItem()
        XCTAssertTrue(engine.listeningForAnswer)
        XCTAssertEqual(listener.listens.last, .yesNo)

        listener.hear("no thanks")
        try await eventually("reading to carry on") { player.currentId == "seg_0_2" }
        XCTAssertFalse(engine.listeningForAnswer)
    }

    func testAnUnclearAnswerIsAskedAgainThenLeftToTheButtons() async throws {
        try await playToThePrompt()
        try await eventually("the question to be read out") { player.currentId == "ask_figure_1" }
        let asks = player.started.count
        player.finishItem()
        listener.hear("what was that")
        try await eventually("it to ask again") { player.started.count == asks + 1 }
        player.finishItem()
        listener.hear(nil)
        try await eventually("it to ask a third time") { player.started.count == asks + 2 }
        player.finishItem()
        listener.hear("hmm")
        try await settled()
        XCTAssertEqual(player.started.count, asks + 2)
        XCTAssertNotNil(engine.uiState.session?.pendingPrompt)
    }

    func testWithFigurePromptsOffItKeepsReading() async throws {
        Settings.askAboutFigures = false
        _ = try await openPaper(figures: true)
        player.finishItem()
        try await eventually("the paragraph") { player.currentId == "seg_0_1" }
        player.finishItem()
        try await eventually("reading to carry on") { player.currentId == "seg_0_2" }
        XCTAssertEqual(listener.listens, [])
    }

    func testYesWithNoKeyIsReported() async throws {
        try await playToThePrompt()
        engine.describeYes()
        try await eventually("the problem") { engine.message != nil }
        XCTAssertEqual(engine.message, "Add your free Gemini API key in Settings first.")
        XCTAssertFalse(engine.isDescribing)
    }

    // MARK: - Interruptions

    func testAVoiceInterruptionThatComesToNothingCarriesOnInPlace() async throws {
        _ = try await openPaper()
        player.currentPositionMs = 4_000
        engine.interruptForVoice()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(engine.interjectionState, .listening)

        engine.voiceCancelled()
        try await eventually("narration to come back") { player.isPlaying }
        XCTAssertEqual(player.currentId, "seg_0_0")
        XCTAssertEqual(player.currentPositionMs, 4_000)
        XCTAssertEqual(engine.interjectionState, .idle)
    }

    func testTellingSomethingReturnsToNarrationInPlace() async throws {
        _ = try await openPaper()
        player.currentPositionMs = 3_000
        engine.tell(ReadingEngine.shortReply, "Noted.", voice: .phone)
        try await eventually("Albert to speak") { player.currentId?.hasPrefix("say_") == true }
        if case .telling(let title, let text, _, _, _, _) = engine.interjectionState {
            XCTAssertEqual(title, ReadingEngine.shortReply)
            XCTAssertEqual(text, "Noted.")
        } else {
            XCTFail("Should be telling")
        }

        player.finishItem()
        try await eventually("narration to come back") { player.currentId == "seg_0_0" && player.isPlaying }
        XCTAssertEqual(player.currentPositionMs, 3_000)
        XCTAssertEqual(engine.interjectionState, .idle)
    }

    func testARecapIsFollowedByWaitingNotNarration() async throws {
        _ = try await openPaper()
        player.currentPositionMs = 3_000
        engine.tell("Recap", "So far, residual networks.", voice: .phone, waits: true)
        try await eventually("Albert to speak") { player.currentId?.hasPrefix("say_") == true }
        XCTAssertTrue(phone.rendered.last?.hasSuffix("Done. Waiting for your next instruction.") == true)
        XCTAssertFalse(engine.isWaitingAfterAside)
        player.finishItem()
        try await eventually("it to wait") { engine.isWaitingAfterAside }
        XCTAssertFalse(player.isPlaying)
        // Play carries on with the paper, from where it was.
        engine.togglePlayPause()
        try await eventually("narration to come back") { player.currentId == "seg_0_0" && player.isPlaying }
        XCTAssertEqual(player.currentPositionMs, 3_000)
        XCTAssertEqual(engine.interjectionState, .idle)
    }

    func testAPausedNarrationStaysPausedAfterAnInterruption() async throws {
        _ = try await openPaper()
        engine.togglePlayPause()
        engine.tell(ReadingEngine.shortReply, "Noted.", voice: .phone)
        try await eventually("Albert to speak") { player.currentId?.hasPrefix("say_") == true }
        player.finishItem()
        try await eventually("narration to be loaded") { player.currentId == "seg_0_0" }
        XCTAssertFalse(player.isPlaying)
    }

    func testAsideResumesOnlyIfItWasPlaying() async throws {
        _ = try await openPaper()
        engine.pauseForAside()
        XCTAssertFalse(player.isPlaying)
        engine.endAside()
        XCTAssertTrue(player.isPlaying)

        engine.togglePlayPause()
        engine.pauseForAside()
        engine.endAside()
        XCTAssertFalse(player.isPlaying)
    }

    func testAQuestionWithNoKeyFailsAndCanBeDismissed() async throws {
        _ = try await openPaper()
        engine.startListening()
        engine.submitQuestion("What is this?")
        try await eventually("the failure") { if case .failed = engine.interjectionState { return true } else { return false } }
        engine.dismissInterjection()
        try await eventually("narration to come back") { player.isPlaying }
    }

    func testProblemsAreAnnouncedOnceWhenThereMayBeNoScreen() async throws {
        engine.announceProblems = true
        _ = try await openPaper()
        engine.describeNo() // nothing pending: a conflict
        try await eventually("the problem") { engine.message != nil }
        try await eventually("Albert to say it") { player.currentId?.hasPrefix("say_") == true }
    }

    // MARK: - The summary

    func testTheSummaryIsReadInPlaceOfNarrationAndComesBackWhenLeft() async throws {
        _ = try await openPaper()
        player.currentPositionMs = 2_000
        engine.pauseForAside()
        engine.toggleSummary("A summary.")
        XCTAssertEqual(engine.summarySpeech, .preparing)
        try await eventually("the summary") { player.currentId == "summary" }
        XCTAssertEqual(engine.summarySpeech, .ready)
        XCTAssertTrue(player.isPlaying)

        engine.toggleSummary("A summary.")
        XCTAssertFalse(player.isPlaying)

        engine.endAside()
        try await eventually("narration back") { player.currentId == "seg_0_0" }
        XCTAssertEqual(engine.summarySpeech, .off)
        XCTAssertEqual(player.currentPositionMs, 2_000)
        XCTAssertTrue(player.isPlaying) // it was going before the summary screen opened
    }

    func testMovesCantHappenUnderTheSummary() async throws {
        _ = try await openPaper()
        engine.toggleSummary("A summary.")
        try await eventually("the summary") { player.currentId == "summary" }
        engine.next()
        try await settled()
        XCTAssertEqual(player.currentId, "summary")
        XCTAssertEqual(engine.uiState.session?.segmentIndex, 0)
    }

    func testTheSummaryFinishingPutsTheButtonBack() async throws {
        _ = try await openPaper()
        engine.toggleSummary("A summary.")
        try await eventually("the summary") { player.currentId == "summary" }
        player.finishItem()
        XCTAssertEqual(engine.summarySpeech, .off)
    }

    func testAlbertSpeakingOverTheSummaryResetsItsButton() async throws {
        _ = try await openPaper()
        engine.toggleSummary("A summary.")
        try await eventually("the summary") { player.currentId == "summary" }
        engine.tell(ReadingEngine.shortReply, "Noted.", voice: .phone)
        XCTAssertEqual(engine.summarySpeech, .off)
    }

    // MARK: - Sessions

    func testReopeningThePaperThatsPlayingLeavesItAlone() async throws {
        let id = try await openPaper()
        let starts = player.started.count
        engine.open(id)
        try await settled()
        XCTAssertEqual(player.started.count, starts)
        XCTAssertTrue(player.isPlaying)
    }

    func testClosingEndsItAndRemembersThePlace() async throws {
        let id = try await openPaper()
        player.finishItem()
        try await eventually("the second paragraph") { player.currentId == "seg_0_1" }
        engine.close(id)
        XCTAssertNil(engine.paperId)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(engine.uiState, .loading)

        engine.open(id)
        try await eventually("it to pick up where it was") { player.currentId == "seg_0_1" }
    }

    func testASessionChangeIsTold() async throws {
        var told: [String?] = []
        engine.onSessionChanged = { told.append($0) }
        let id = try await openPaper()
        engine.close(id)
        XCTAssertEqual(told, [id, nil])
    }

    func testAMissingPaperIsAnErrorThatCanBeRetried() async throws {
        engine.open("no-such-paper")
        try await eventually("the error") { if case .error = engine.uiState { return true } else { return false } }
        try TestWorld.addPaper("no-such-paper")
        engine.retryLoad()
        try await eventually("it to load") { player.isPlaying }
        try await Core.deletePaper("no-such-paper")
    }

    func testCurrentParagraphSaysWhereInThePdf() async throws {
        _ = try await openPaper()
        let paragraph = engine.currentParagraph()
        XCTAssertEqual(paragraph.page, 1)
        XCTAssertEqual(paragraph.text, "1 Introduction")
    }

    func testSpeechTermsAreTheHeadingsWithoutNumbers() async throws {
        _ = try await openPaper()
        XCTAssertEqual(engine.speechTerms(), ["Introduction", "Method"])
    }

    func testSpokenFractionFollowsThePlayer() async throws {
        _ = try await openPaper()
        player.durationMs = 10_000
        player.currentPositionMs = 5_000
        try await eventually("its parts to be known") { engine.spokenFraction("seg_0_0") > 0 }
        XCTAssertEqual(engine.spokenFraction("seg_0_0"), 0.5, accuracy: 0.01)
        XCTAssertEqual(engine.spokenFraction("something-else"), 0)
    }

    func testNotesAreSaved() async throws {
        let id = try await openPaper()
        engine.addNote("todo: read Smith et al.")
        try await settled()
        let removed = try await Core.deleteLastNote(id)
        XCTAssertEqual(removed?.kind, "todo")
    }
}
