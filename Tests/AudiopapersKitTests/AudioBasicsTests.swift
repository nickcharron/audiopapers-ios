import XCTest
@testable import AudiopapersKit

private func eventsOf(_ endpointer: SpeechEndpointer, _ count: Int, _ frame: () -> [Int16]) -> [SpeechEndpointer.Event] {
    (0..<count).map { _ in endpointer.feed(frame()) }.filter { $0 != .none }
}

final class PcmRingTests: XCTestCase {
    func testGivesBackTheLatestSamplesOldestFirst() {
        let ring = PcmRing(capacity: 4)
        ring.write([1, 2])
        ring.write([3])
        XCTAssertEqual(ring.latest(2), [2, 3])
        XCTAssertEqual(ring.latest(10), [1, 2, 3])
    }

    func testForgetsWhatFallsOffTheEnd() {
        let ring = PcmRing(capacity: 3)
        ring.write([1, 2, 3, 4, 5])
        XCTAssertEqual(ring.latest(3), [3, 4, 5])
        XCTAssertEqual(ring.capacity, 3)
    }

    func testStartsEmptyAndCanBeCleared() {
        let ring = PcmRing(capacity: 3)
        XCTAssertEqual(ring.latest(3).count, 0)
        ring.write([1])
        ring.clear()
        XCTAssertEqual(ring.latest(3).count, 0)
    }
}

final class WakeTriggerTests: XCTestCase {
    private func fires(_ trigger: WakeTrigger, _ scores: Float...) -> [Bool] {
        scores.map { trigger.feed($0, threshold: 0.5) }
    }

    func testFiresWhenScoresHoldForItsPatience() {
        XCTAssertEqual(fires(WakeTrigger(patience: 2), 0.9, 0.9), [false, true])
        XCTAssertEqual(fires(WakeTrigger(patience: 1), 0.5), [true])
    }

    func testASingleSpikeDoesntFire() {
        XCTAssertEqual(fires(WakeTrigger(patience: 2), 0.9, 0.1, 0.9, 0.1), [false, false, false, false])
    }

    func testOnlyFiresOnceUntilScoresDrop() {
        XCTAssertEqual(fires(WakeTrigger(patience: 2), 0.9, 0.9, 0.9, 0.9, 0.1, 0.9, 0.9), [false, true, false, false, false, false, true])
    }

    func testResetForgetsARun() {
        let trigger = WakeTrigger(patience: 2)
        _ = trigger.feed(0.9, threshold: 0.5)
        trigger.reset()
        XCTAssertEqual(fires(trigger, 0.9, 0.9), [false, true])
    }
}

final class SpeechEndpointerTests: XCTestCase {
    private var generator = SystemRandomNumberGenerator()

    private func silence(level: Float = 0.0005) -> [Int16] {
        (0..<micFrameSamples).map { _ in Int16(Float.random(in: 0..<1, using: &generator) * level * Float(Int16.max)) }
    }

    private func talking(level: Float = 0.2) -> [Int16] {
        (0..<micFrameSamples).map { i in
            Int16(sin(2 * Double.pi * 300 * Double(i) / Double(micSampleRate)) * Double(level) * Double(Int16.max))
        }
    }

    private func endpointer() -> SpeechEndpointer { SpeechEndpointer(noSpeechFrames: 20, endSilenceFrames: 5, maxFrames: 100) }

    func testSilenceAloneEndsInNoSpeech() {
        let endpointer = endpointer()
        XCTAssertEqual(eventsOf(endpointer, 30) { silence() }, [.noSpeech])
        XCTAssertFalse(endpointer.heardSpeech)
    }

    func testSpeechThenSilenceEnds() {
        let endpointer = endpointer()
        _ = eventsOf(endpointer, 3) { silence() }
        XCTAssertEqual(eventsOf(endpointer, 10) { talking() }, [.speechStarted])
        XCTAssertTrue(endpointer.heardSpeech)
        XCTAssertEqual(eventsOf(endpointer, 10) { silence() }, [.speechEnded])
    }

    func testAPauseShorterThanTheEndSilenceDoesntEndIt() {
        let endpointer = endpointer()
        _ = eventsOf(endpointer, 3) { silence() }
        _ = eventsOf(endpointer, 10) { talking() }
        XCTAssertEqual(eventsOf(endpointer, 3) { silence() }, [])
        XCTAssertEqual(eventsOf(endpointer, 5) { talking() }, [])
    }

    func testNothingEndingIsCutOffAtTheLimit() {
        let endpointer = endpointer()
        _ = eventsOf(endpointer, 3) { silence() }
        XCTAssertEqual(eventsOf(endpointer, 120) { talking() }, [.speechStarted, .tooLong])
    }

    func testSteadyNoiseIsntSpeechButTalkingOverItIs() {
        let endpointer = endpointer()
        func noisy(_ extra: [Int16]? = nil) -> [Int16] {
            (0..<micFrameSamples).map { i in
                let noise = (Float.random(in: 0..<1, using: &generator) - 0.5) * 0.03 * Float(Int16.max)
                return Int16(noise + Float(extra?[i] ?? 0))
            }
        }
        XCTAssertEqual(eventsOf(endpointer, 15) { noisy() }, [])
        XCTAssertEqual(eventsOf(endpointer, 4) { noisy(talking()) }, [.speechStarted])
    }

    func testSomeoneAlreadyTalkingCountsGivenAFloorFromBeforehand() {
        let floor = SpeechEndpointer.levelDb(silence())
        let told = SpeechEndpointer(noSpeechFrames: 20, endSilenceFrames: 5, maxFrames: 100, initialNoiseFloorDb: floor)
        let untold = endpointer()
        XCTAssertEqual(eventsOf(told, 10) { talking() }, [.speechStarted])
        XCTAssertEqual(eventsOf(untold, 10) { talking() }, [])
    }

    func testOnlyEndsOnce() {
        let endpointer = endpointer()
        _ = eventsOf(endpointer, 30) { silence() }
        XCTAssertEqual(endpointer.feed(talking()), SpeechEndpointer.Event.none)
    }
}

final class SentencesTests: XCTestCase {
    func testFindsTheSentenceAroundAnOffset() {
        let text = "First one. Second one! Third?"
        func sentence(_ offset: Int) -> String {
            let range = Sentences.around(text, offset: offset)
            return String(Array(text)[range])
        }
        XCTAssertEqual(sentence(0), "First one.")
        XCTAssertEqual(sentence(5), "First one.")
        XCTAssertEqual(sentence(12), "Second one!")
        XCTAssertEqual(sentence(100), "Third?")
    }

    func testCopesWithNothing() {
        XCTAssertEqual(Sentences.around("", offset: 3), 0..<0)
    }
}

final class WavTests: XCTestCase {
    func testWritesAHeaderAndSixteenBitSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Wav.write([0, 1, -1, 2], sampleRate: 24_000, to: url)
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(bytes.count, 44 + 8)
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(UInt32(bytes[24]) | UInt32(bytes[25]) << 8 | UInt32(bytes[26]) << 16, 24_000)
        XCTAssertEqual(Array(bytes[46..<48]), [0xFF, 0x7F]) // 1 -> Int16.max
        XCTAssertEqual(Array(bytes[50..<52]), [0xFF, 0x7F]) // clamped
    }
}

final class KokoroStylesTests: XCTestCase {
    func testReadsAVoicesStyleForALength() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = 2 * KokoroStyles.stylesPerVoice * KokoroStyles.styleSize
        var data = Data(capacity: count * 4)
        for i in 0..<count { withUnsafeBytes(of: Float(i).bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        try data.write(to: url)

        let style = try KokoroStyles.style(file: url, voice: 1, length: 3)

        let start = (1 * KokoroStyles.stylesPerVoice + 3) * KokoroStyles.styleSize
        XCTAssertEqual(style.count, KokoroStyles.styleSize)
        XCTAssertEqual(style[0], Float(start))
        XCTAssertEqual(style[255], Float(start + 255))
    }
}

private final class ShapeCheckingModel: OnnxModel {
    var shapes: [[Int]] = []
    var inputs: [[Float]] = []
    let output: [Float]
    init(output: [Float]) { self.output = output }
    func run(_ input: [Float], shape: [Int]) throws -> [Float] {
        shapes.append(shape)
        inputs.append(input)
        return output
    }
}

final class OpenWakeWordDetectorTests: XCTestCase {
    func testFeedsEachModelTheShapeItWasTrainedOnAndWarmsUp() throws {
        let mel = ShapeCheckingModel(output: [Float](repeating: 10, count: 8 * 32))
        let embedding = ShapeCheckingModel(output: [Float](repeating: 0.5, count: 96))
        let classifier = ShapeCheckingModel(output: [0.75])
        let detector = OpenWakeWordDetector(melspectrogram: mel, embedding: embedding, classifier: classifier)
        let frame = [Int16](repeating: 100, count: micFrameSamples)

        XCTAssertEqual(try detector.score(frame), 0) // the audio window isn't full yet
        XCTAssertTrue(mel.shapes.isEmpty)
        for _ in 2..<26 { XCTAssertEqual(try detector.score(frame), 0) }
        XCTAssertEqual(try detector.score(frame), 0.75)

        XCTAssertEqual(mel.shapes.last, [1, 1760])
        XCTAssertEqual(embedding.shapes.last, [1, 76, 32, 1])
        XCTAssertEqual(classifier.shapes.last, [1, 16, 96])
        // Scaled to match Google's own spectrogram: 10 / 10 + 2.
        XCTAssertEqual(embedding.inputs.last?.last, 3)
        // Samples go in unscaled, as 16-bit values.
        XCTAssertEqual(mel.inputs.last?.last, 100)
        XCTAssertEqual(classifier.inputs.last?.count, 16 * 96)
    }

    func testResetStartsTheWarmUpAgain() throws {
        let detector = OpenWakeWordDetector(
            melspectrogram: ShapeCheckingModel(output: [Float](repeating: 0, count: 8 * 32)),
            embedding: ShapeCheckingModel(output: [Float](repeating: 0, count: 96)),
            classifier: ShapeCheckingModel(output: [0.9])
        )
        let frame = [Int16](repeating: 0, count: micFrameSamples)
        for _ in 0..<26 { _ = try detector.score(frame) }
        XCTAssertEqual(try detector.score(frame), 0.9)
        detector.reset()
        XCTAssertEqual(try detector.score(frame), 0)
    }
}
