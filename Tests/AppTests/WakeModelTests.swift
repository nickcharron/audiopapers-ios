import AudiopapersKit
import XCTest
@testable import Audiopapers

private let wavHeaderBytes = 44

/// Runs the real models on recordings kept for this, and compares against what the reference steps
/// in the main repo's scripts/train_wake_word.py give (expected_scores.json, written by its
/// "fixtures" step): the app has to feed the classifier what it was trained on.
final class WakeModelTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("wakeword")
    }

    private func frames(_ name: String) throws -> [[Int16]] {
        // 16 kHz, 16-bit mono after a plain 44-byte header, as the training script writes them.
        let data = try Data(contentsOf: resources.appendingPathComponent("\(name).wav")).dropFirst(wavHeaderBytes)
        let samples = data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        return stride(from: 0, to: samples.count - micFrameSamples + 1, by: micFrameSamples).map { Array(samples[$0..<($0 + micFrameSamples)]) }
    }

    private func assertMatchesReference(_ name: String) throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("expected_scores.json"))) as? [String: [Double]]
        let reference = try XCTUnwrap(expected?[name])
        let detector = try WakeModel.detector()
        let actual = try frames(name).map { try detector.score($0) }
        XCTAssertEqual(actual.count, reference.count)
        for (i, score) in actual.enumerated() {
            XCTAssertEqual(Double(score), reference[i], accuracy: 0.02, "\(name), frame \(i)")
        }
    }

    func testTheWakePhraseScoresAsTheReferenceDoes() throws {
        try assertMatchesReference("hey_albert_0")
        try assertMatchesReference("hey_albert_1")
    }

    func testNarrationScoresAsTheReferenceDoes() throws {
        try assertMatchesReference("narration")
    }
}

/// The real bridge, with the real bundled Python: on the laptop that's a different Python.
@MainActor
final class EmbeddedPythonTests: XCTestCase {
    func testTheCoreRunsInsideTheApp() async throws {
        let services = try XCTUnwrap(AppServices.shared)
        XCTAssertNil(services.engine.paperId)
        let parts = try await Core.splitSpeech("One two. Three four.", limit: 100)
        XCTAssertEqual(parts, ["One two. Three four."])
        let papers = try await Core.listPapers()
        XCTAssertNotNil(papers)
    }

    func testPythonsBinaryModulesLoad() async throws {
        // Checking a file's hash needs hashlib, reached by trying to open one that isn't there.
        do {
            try await Core.kokoroInstall(downloads: URL(fileURLWithPath: "/no/such/folder"))
            XCTFail("Should have thrown")
        } catch let error as CoreError {
            XCTAssertEqual(error.type, "network") // an OSError: it got as far as opening the file
        }
    }

    func testHttpsWorksWithTheBundledCertificates() async throws {
        // Gemini turns a made-up key away, which means the TLS connection itself worked.
        do {
            try await Core.checkKey("not-a-real-key", model: nil)
            XCTFail("Should have thrown")
        } catch let error as CoreError {
            XCTAssertNotEqual(error.type, "network", error.message)
        }
    }
}
