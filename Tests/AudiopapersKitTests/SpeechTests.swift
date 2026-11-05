import XCTest
@testable import AudiopapersKit

@MainActor
final class SpeechTests: XCTestCase {
    private var dir: URL!
    private var phone: FakePhoneVoice!
    private var kokoro: FakeKokoro!
    private var speech: Speech!

    override func setUp() async throws {
        try TestWorld.start()
        Settings.phoneVoice = nil
        dir = TestWorld.root.appendingPathComponent("speech-\(UUID().uuidString)")
        phone = FakePhoneVoice()
        kokoro = FakeKokoro()
        speech = Speech(phone: phone, kokoro: kokoro)
    }

    private var kokoroVoice: Voice { .kokoro(Core.catalog.kokoroVoice(named: "am_michael")!) }

    func testThePhoneVoiceRendersOnceAndKeepsIt() async throws {
        let first = try await speech.render("Hello there.", dir: dir, name: "a", voice: .phone)
        let second = try await speech.render("Hello there.", dir: dir, name: "a", voice: .phone)
        XCTAssertEqual(first, second)
        XCTAssertEqual(phone.rendered, ["Hello there."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first[0].path))
    }

    func testChangedTextRendersAgain() async throws {
        _ = try await speech.render("One.", dir: dir, name: "a", voice: .phone)
        _ = try await speech.render("Two.", dir: dir, name: "a", voice: .phone)
        XCTAssertEqual(phone.rendered, ["One.", "Two."])
    }

    func testAPickedVoiceIsPartOfTheFileName() async throws {
        let plain = try await speech.render("Hello.", dir: dir, name: "a", voice: .phone)
        Settings.phoneVoice = "com.apple.voice.Samantha"
        defer { Settings.phoneVoice = nil }
        let picked = try await speech.render("Hello.", dir: dir, name: "a", voice: .phone)
        XCTAssertNotEqual(plain, picked)
        XCTAssertEqual(phone.picked.last, "com.apple.voice.Samantha")
        XCTAssertEqual(Voice.phone.label, "phone:com.apple.voice.Samantha")
    }

    func testAFailedRenderLeavesNothingBehind() async throws {
        phone.failing = true
        do {
            _ = try await speech.render("Hello.", dir: dir, name: "a", voice: .phone)
            XCTFail("Should have thrown")
        } catch let error as SpeechFailure {
            XCTAssertEqual(error.message, "Text-to-speech failed")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testKokoroRendersInPartsHandingEachOverAsItsReady() async throws {
        let text = "First one. " + (0..<40).map { "Sentence \($0) goes on for a while." }.joined(separator: " ")
        var parts: [URL] = []
        let files = try await speech.render(text, dir: dir, name: "a", voice: kokoroVoice) { parts.append($0) }
        XCTAssertEqual(files, parts)
        XCTAssertGreaterThan(files.count, 2)
        XCTAssertEqual(kokoro.rendered.first, "First one.")
        XCTAssertEqual(phone.rendered, [])

        _ = try await speech.render(text, dir: dir, name: "a", voice: kokoroVoice)
        XCTAssertEqual(kokoro.rendered.count, files.count)
    }

    func testPartTextsMatchWhatEachVoiceRenders() async throws {
        let phoneParts = try await speech.partTexts("One. Two.", voice: .phone)
        XCTAssertEqual(phoneParts, ["One. Two."])
        let geminiParts = try await speech.partTexts("One. Two.", voice: .gemini(name: "Charon", model: nil))
        XCTAssertEqual(geminiParts, ["One. Two."])
        let kokoroParts = try await speech.partTexts("One. Two.", voice: kokoroVoice)
        XCTAssertEqual(kokoroParts, ["One.", "Two."])
    }

    func testAGeminiVoiceWithoutAKeyFallsBackToThePhoneForTheRestOfTheSession() async throws {
        Settings.geminiKey = nil
        var told: [String] = []
        speech.onGeminiUnavailable = { told.append($0) }
        let voice = Voice.gemini(name: "Charon", model: nil)

        _ = try await speech.render("One.", dir: dir, name: "a", voice: voice)
        _ = try await speech.render("Two.", dir: dir, name: "b", voice: voice)

        XCTAssertEqual(phone.rendered, ["One.", "Two."])
        XCTAssertEqual(told.count, 1)
        XCTAssertTrue(told[0].contains("The Gemini voice stopped working"))

        speech.resumeGemini()
        _ = try await speech.render("Three.", dir: dir, name: "c", voice: voice)
        XCTAssertEqual(told.count, 2)
    }

    func testADownloadInAGeminiVoiceSaysWhyInsteadOfFallingBack() async throws {
        Settings.geminiKey = nil
        do {
            _ = try await speech.render("One.", dir: dir, name: "a", voice: .gemini(name: "Charon", model: nil), fallback: false)
            XCTFail("Should have thrown")
        } catch let error as CoreError {
            XCTAssertEqual(error.type, "no_key")
        }
        XCTAssertEqual(phone.rendered, [])
    }

    func testSavedGeminiAudioPlaysWithoutAKey() async throws {
        Settings.geminiKey = nil
        ensureDirectory(dir)
        let saved = dir.appendingPathComponent("a-g-Charon-\(stableHash("One.")).wav")
        try Data("audio".utf8).write(to: saved)
        let files = try await speech.render("One.", dir: dir, name: "a", voice: .gemini(name: "Charon", model: nil))
        XCTAssertEqual(files, [saved])
    }

    func testVoicesFallBackToThePhoneUntilKokoroIsInstalled() throws {
        Settings.voiceEngine = .kokoro
        defer { Settings.voiceEngine = .phone }
        XCTAssertEqual(Voice.current(), .phone)

        let ready = KokoroModel.dir.appendingPathComponent("ready")
        ensureDirectory(KokoroModel.dir)
        try Data().write(to: ready)
        defer { KokoroModel.delete() }
        XCTAssertTrue(Voice.current().isKokoro)
        XCTAssertEqual(Voice.current().label, "kokoro:am_michael")
    }
}
