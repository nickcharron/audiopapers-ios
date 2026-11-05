import Foundation

/// How the microphone's audio is cut up for wake-word detection: 80 ms at 16 kHz.
public let micSampleRate = 16_000
public let micFrameSamples = 1280

/// The last few seconds of microphone audio, so what's said right after "Hey Albert" can be handed
/// to the speech recognizer even though it only starts once the phrase has been heard. Not
/// thread-safe: MicPipeline guards it.
public final class PcmRing {
    private var samples: [Int16]
    private var next = 0
    private var filled = 0

    public init(capacity: Int) { samples = [Int16](repeating: 0, count: capacity) }

    public var capacity: Int { samples.count }

    public func write(_ frame: [Int16]) {
        for sample in frame {
            samples[next] = sample
            next = (next + 1) % samples.count
        }
        filled = min(filled + frame.count, samples.count)
    }

    /// The most recent `count` samples, oldest first, or fewer if there aren't that many.
    public func latest(_ count: Int) -> [Int16] {
        let size = min(count, filled)
        let start = (next - size + samples.count) % samples.count
        return (0..<size).map { samples[(start + $0) % samples.count] }
    }

    public func clear() {
        next = 0
        filled = 0
    }
}

/// Decides from loudness alone when someone has started and stopped talking, a frame at a time.
/// The recognizer has its own idea of this and usually gets there first; this is what ends a
/// capture when it doesn't, and what tells silence after a false "Hey Albert" apart from a command
/// the recognizer failed on.
public final class SpeechEndpointer {
    public enum Event { case none, speechStarted, speechEnded, noSpeech, tooLong }

    private static let speechAboveFloorDb: Float = 9
    private static let quietestSpeechDb: Float = -58
    private static let speechStartFrames = 3
    private static let floorFall: Float = 0.3
    private static let floorRiseDb: Float = 0.05

    public private(set) var heardSpeech = false

    private let noSpeechFrames: Int
    private let endSilenceFrames: Int
    private let maxFrames: Int
    private var frames = 0
    // Without a floor to start from, the first frame is taken as one. Someone who carries straight
    // on from "Hey Albert" is already talking by then, so pass one in when it's known.
    private var noiseFloor: Float
    private var loudRun = 0
    private var quietRun = 0
    private var ended = false

    public init(noSpeechFrames: Int, endSilenceFrames: Int, maxFrames: Int, initialNoiseFloorDb: Float = .nan) {
        self.noSpeechFrames = noSpeechFrames
        self.endSilenceFrames = endSilenceFrames
        self.maxFrames = maxFrames
        noiseFloor = initialNoiseFloorDb
    }

    public func feed(_ frame: [Int16]) -> Event {
        if ended { return .none }
        frames += 1
        let level = SpeechEndpointer.levelDb(frame)
        // The floor follows quiet quickly and loud slowly, so it tracks a car's steady noise
        // without climbing up to meet someone talking over it.
        if noiseFloor.isNaN {
            noiseFloor = level
        } else if level < noiseFloor {
            noiseFloor += (level - noiseFloor) * SpeechEndpointer.floorFall
        } else {
            noiseFloor += SpeechEndpointer.floorRiseDb
        }
        let loud = level > noiseFloor + SpeechEndpointer.speechAboveFloorDb && level > SpeechEndpointer.quietestSpeechDb
        if loud {
            loudRun += 1
            quietRun = 0
        } else {
            loudRun = 0
            quietRun += 1
        }
        if frames >= maxFrames { return finish(.tooLong) }
        if !heardSpeech && loudRun >= SpeechEndpointer.speechStartFrames {
            heardSpeech = true
            return .speechStarted
        }
        if heardSpeech && quietRun >= endSilenceFrames { return finish(.speechEnded) }
        if !heardSpeech && frames >= noSpeechFrames { return finish(.noSpeech) }
        return .none
    }

    private func finish(_ event: Event) -> Event {
        ended = true
        return event
    }

    /// A frame's loudness, in dB below full scale.
    public static func levelDb(_ frame: [Int16]) -> Float {
        if frame.isEmpty { return -96 }
        var sum = 0.0
        for sample in frame {
            let scaled = Double(sample) / Double(Int16.max)
            sum += scaled * scaled
        }
        let rms = (sum / Double(frame.count)).squareRoot()
        return rms <= 1e-5 ? -96 : Float(20 * log10(rms))
    }
}

/// Fires when scores hold at or above a threshold for `patience` frames in a row, then not again
/// until they've dropped below it. Only the threshold changes with Settings.
public final class WakeTrigger {
    public static let defaultPatience = 2

    private let patience: Int
    private var run = 0
    private var fired = false

    public init(patience: Int = WakeTrigger.defaultPatience) { self.patience = patience }

    public func feed(_ score: Float, threshold: Float) -> Bool {
        if score < threshold {
            run = 0
            fired = false
            return false
        }
        run += 1
        if fired || run < patience { return false }
        fired = true
        return true
    }

    public func reset() {
        run = 0
        fired = false
    }
}

/// Says how likely it is that the audio so far has just ended in the wake phrase.
public protocol WakeDetector: AnyObject {
    /// The score for one more micFrameSamples of audio, from 0 to 1.
    func score(_ frame: [Int16]) throws -> Float

    /// Forgets the audio so far, for after a gap in it.
    func reset()
}

/// One small ONNX model: a tensor of floats in, a tensor of floats out.
public protocol OnnxModel: AnyObject {
    func run(_ input: [Float], shape: [Int]) throws -> [Float]
}

/// "Hey Albert", found the openWakeWord way: audio becomes a mel spectrogram, that becomes Google's
/// general speech embeddings, and a small classifier trained on the phrase looks at the last 16 of
/// them. These steps have to match what the classifier was trained on (scripts/train_wake_word.py
/// in the main audiopapers repo, whose StreamingDetector is the reference WakeDetectorTests compare
/// this against). Used from one thread at a time.
public final class OpenWakeWordDetector: WakeDetector {
    private static let melInputSamples = micFrameSamples + 480 // three more 10 ms hops, for eight new mel frames
    private static let melBins = 32
    private static let melWindowFrames = 76
    private static let embeddingSize = 96
    private static let embeddingWindow = 16
    private static let framesToFillAudio = 2
    // A full window of real spectrogram at eight mel frames a step, then 16 embeddings of it.
    private static let warmupFrames = 10 + embeddingWindow

    private let melModel: OnnxModel
    private let embeddingModel: OnnxModel
    private let classifierModel: OnnxModel

    private var audio = [Float](repeating: 0, count: melInputSamples)
    private var mel = [Float](repeating: 1, count: melWindowFrames * melBins)
    private var embeddings = [Float](repeating: 0, count: embeddingWindow * embeddingSize)
    private var frames = 0

    public init(melspectrogram: OnnxModel, embedding: OnnxModel, classifier: OnnxModel) {
        melModel = melspectrogram
        embeddingModel = embedding
        classifierModel = classifier
    }

    public func reset() {
        audio = [Float](repeating: 0, count: audio.count)
        mel = [Float](repeating: 1, count: mel.count)
        embeddings = [Float](repeating: 0, count: embeddings.count)
        frames = 0
    }

    public func score(_ frame: [Int16]) throws -> Float {
        precondition(frame.count == micFrameSamples, "Expected \(micFrameSamples) samples, got \(frame.count)")
        audio.removeFirst(frame.count)
        audio.append(contentsOf: frame.map(Float.init))
        frames += 1
        if frames < OpenWakeWordDetector.framesToFillAudio { return 0 }

        try pushMelFrames()
        try pushEmbedding()
        return frames < OpenWakeWordDetector.warmupFrames ? 0 : try classify()
    }

    private func pushMelFrames() throws {
        let values = try melModel.run(audio, shape: [1, audio.count])
        mel.removeFirst(values.count)
        // The model's output scaled to match Google's own spectrogram, as openWakeWord does.
        mel.append(contentsOf: values.map { $0 / 10 + 2 })
    }

    private func pushEmbedding() throws {
        let output = try embeddingModel.run(mel, shape: [1, OpenWakeWordDetector.melWindowFrames, OpenWakeWordDetector.melBins, 1])
        embeddings.removeFirst(OpenWakeWordDetector.embeddingSize)
        embeddings.append(contentsOf: output.prefix(OpenWakeWordDetector.embeddingSize))
    }

    private func classify() throws -> Float {
        let output = try classifierModel.run(embeddings, shape: [1, OpenWakeWordDetector.embeddingWindow, OpenWakeWordDetector.embeddingSize])
        return output[0]
    }
}

/// Audio files the app writes itself.
public enum Wav {
    /// Writes `samples` (-1 to 1) as a 16-bit mono WAV.
    public static func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data(capacity: 44 + samples.count * 2)
        func append(_ text: String) { data.append(contentsOf: text.utf8) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        append("RIFF"); append(36 + dataBytes); append("WAVE")
        append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        append("data"); append(dataBytes)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(UInt16(bitPattern: Int16(clamped * Float(Int16.max))))
        }
        try data.write(to: url)
    }
}

/// The Kokoro model's voices.bin: float32, [voice][length][256].
public enum KokoroStyles {
    public static let styleSize = 256
    static let stylesPerVoice = 510 // one per token count, as voices.bin stores them

    /// The voice's style vector for a passage of `length` tokens.
    public static func style(file: URL, voice: Int, length: Int) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64((voice * stylesPerVoice + length) * styleSize * 4))
        guard let data = try handle.read(upToCount: styleSize * 4), data.count == styleSize * 4 else {
            throw CoreError(type: "internal", message: "The voice's style data is cut short")
        }
        return data.withUnsafeBytes { raw in
            (0..<styleSize).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}

/// Finds which sentence of a paragraph is being read, for the reader's highlight.
public enum Sentences {
    /// The sentence containing character `offset` in `text` as a range of character offsets,
    /// without its trailing space.
    public static func around(_ text: String, offset: Int) -> Range<Int> {
        let characters = Array(text)
        if characters.isEmpty { return 0..<0 }
        let at = min(max(offset, 0), characters.count - 1)
        var gaps: [Range<Int>] = []
        var i = 1
        while i < characters.count {
            if characters[i].isWhitespace && ".!?".contains(characters[i - 1]) {
                var end = i
                while end < characters.count && characters[end].isWhitespace { end += 1 }
                gaps.append(i..<end)
                i = end
            }
            i += 1
        }
        let start = gaps.last { $0.upperBound - 1 < at }?.upperBound ?? 0
        let end = gaps.first { $0.upperBound - 1 >= at && $0.lowerBound > start }?.lowerBound ?? characters.count
        return start..<end
    }
}
