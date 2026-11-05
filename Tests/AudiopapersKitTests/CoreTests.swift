import XCTest
@testable import AudiopapersKit

final class CoreTests: XCTestCase {
    override func setUp() async throws {
        try TestWorld.start()
    }

    func testListsPapersFromThePythonCore() async throws {
        let id = try TestWorld.addPaper()
        let papers = try await Core.listPapers()
        XCTAssertTrue(papers.contains { $0.paperId == id })
    }

    func testAPaperThatDoesntExistIsATypedError() async {
        do {
            _ = try await Core.paperDetail("no-such-paper")
            XCTFail("Should have thrown")
        } catch let error as CoreError {
            XCTAssertEqual(error.type, "not_found")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testNullResultsComeBackAsNil() async throws {
        let id = try TestWorld.addPaper()
        let summary = try await Core.getSummary(id)
        XCTAssertNil(summary)
        let neither = try await Core.yesOrNo("next section")
        XCTAssertNil(neither)
        let yes = try await Core.yesOrNo("yes")
        XCTAssertEqual(yes, true)
    }

    func testAMissingKeyIsCaughtBeforeReachingPython() async throws {
        Settings.geminiKey = nil
        let id = try TestWorld.addPaper()
        do {
            _ = try await Core.answer(id, "What is this?")
            XCTFail("Should have thrown")
        } catch let error as CoreError {
            XCTAssertEqual(error.type, "no_key")
            XCTAssertEqual(error.friendlyMessage, "Add your free Gemini API key in Settings first.")
        }
    }

    func testTextHelpersAreSharedWithTheCore() async throws {
        let blocks = try await Core.summaryBlocks("# Title\n\nSome **bold** text.")
        XCTAssertEqual(blocks.map(\.type), ["heading", "paragraph"])
        XCTAssertEqual(blocks[1].spans?[1], SummarySpan(text: "bold", style: "bold"))
        let speech = try await Core.summarySpeechText("# Title")
        XCTAssertEqual(speech, "Title.")
        let parts = try await Core.splitSpeech("One two. Three four. Five six.", limit: 20)
        XCTAssertEqual(parts, ["One two. Three four.", "Five six."])
    }

    func testUnicodeSurvivesTheBridge() async throws {
        let parts = try await Core.splitSpeech("β 1 = 0.9 “quoted” 日本語", limit: 100)
        XCTAssertEqual(parts, ["β 1 = 0.9 “quoted” 日本語"])
    }

    func testPythonExceptionsArriveAsInternalErrors() async {
        do {
            // Wrong number of arguments: Python raises before the bridge's own error handling.
            let _: [String] = try await Core.splitSpeech("x", limit: 0)
            XCTFail("Should have thrown")
        } catch let error as CoreError {
            XCTAssertEqual(error.type, "invalid")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testTheCatalogIsReadFromTheCorePackage() {
        XCTAssertEqual(Core.catalog.defaultGeminiVoice, "Charon")
        XCTAssertEqual(Core.catalog.kokoroVoice(named: "bf_emma")?.british, true)
        XCTAssertEqual(Core.catalog.listenModes["command"]?.noSpeechMs, 4_000)
        XCTAssertEqual(WakeSensitivity.normal.threshold, 0.1)
    }

    func testFriendlyQuotaMessagesSayWhatToDo() {
        let minute = CoreError(type: "quota", message: "429", scope: "minute", retryAfterS: 7.3)
        XCTAssertEqual(minute.friendlyMessage, "Your free Gemini key allows only a few requests per minute. Wait about 7 seconds and try again.")
        XCTAssertTrue(CoreError(type: "quota", message: "429", scope: "day").friendlyMessage.contains("midnight Pacific"))
    }

    func testStableHashIsStable() {
        XCTAssertEqual(stableHash("hello"), "4f9f2cab")
    }
}
