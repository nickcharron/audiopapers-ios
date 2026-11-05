import AudiopapersKit
import Foundation
import OnnxRuntimeBindings

private let kokoroSampleRate = 24_000

private enum Onnx {
    static let env: ORTEnv? = try? ORTEnv(loggingLevel: .warning)

    static func session(path: String, threads: Int) throws -> ORTSession {
        guard let env else { throw SpeechFailure("ONNX Runtime couldn't start") }
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(threads))
        return try ORTSession(env: env, modelPath: path, sessionOptions: options)
    }

    static func tensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    static func tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape.map { NSNumber(value: $0) })
    }

    static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// One of the wake word's three small models, bundled with the app.
final class WakeModel: OnnxModel {
    private let session: ORTSession
    private let inputName: String
    private let outputName: String

    init(resource: String) throws {
        guard let path = Bundle.main.path(forResource: resource, ofType: "onnx") else {
            throw SpeechFailure("The wake word model \(resource) isn't in the app")
        }
        session = try Onnx.session(path: path, threads: 1)
        guard let input = try session.inputNames().first, let output = try session.outputNames().first else {
            throw SpeechFailure("The wake word model \(resource) has no inputs or outputs")
        }
        inputName = input
        outputName = output
    }

    func run(_ input: [Float], shape: [Int]) throws -> [Float] {
        let tensor = try Onnx.tensor(input, shape: shape)
        let outputs = try session.run(withInputs: [inputName: tensor], outputNames: [outputName], runOptions: nil)
        guard let output = outputs[outputName] else { throw SpeechFailure("The wake word model gave no output") }
        return try Onnx.floats(output)
    }

    static func detector() throws -> WakeDetector {
        OpenWakeWordDetector(
            melspectrogram: try WakeModel(resource: "melspectrogram"),
            embedding: try WakeModel(resource: "embedding_model"),
            classifier: try WakeModel(resource: "hey_albert")
        )
    }
}

/// Runs the Kokoro voice model on the phone (ONNX Runtime, CPU), so reading aloud with it needs no
/// connection and no quota. audiopapers_core turns text into the model's token ids, and the model
/// turns those plus the voice's style vector into audio. The model is loaded once and shared -- by
/// playback and background downloads alike -- and renders one passage at a time, since each render
/// already uses several cores.
final class KokoroEngine: KokoroSynthesizer, @unchecked Sendable {
    private let lock = AsyncLock()
    private var session: ORTSession?

    func synthesize(_ text: String, voice: KokoroVoice, to url: URL) async throws {
        try await lock.withLock {
            let chunks = try await Core.kokoroTokens(text, british: voice.british, modelDir: KokoroModel.dir)
            try Task.checkCancellation()
            let samples = try await Task.detached(priority: .userInitiated) { [self] in
                var samples: [Float] = []
                for chunk in chunks {
                    try Task.checkCancellation()
                    samples.append(contentsOf: try run(chunk, voice: voice.id))
                }
                return samples
            }.value
            if samples.isEmpty { throw SpeechFailure("Kokoro made no audio") }
            try Wav.write(samples, sampleRate: kokoroSampleRate, to: url)
        }
    }

    func release() async {
        await lock.withLock { self.session = nil }
    }

    private func loaded() throws -> ORTSession {
        if let session { return session }
        let threads = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        let created = try Onnx.session(path: KokoroModel.dir.appendingPathComponent("model.int8.onnx").path, threads: threads)
        session = created
        return created
    }

    private func run(_ ids: [Int64], voice: Int) throws -> [Float] {
        let model = try loaded()
        // The model expects the token ids wrapped in a padding token (0) at each end.
        let padded: [Int64] = [0] + ids + [0]
        let style = try KokoroStyles.style(file: KokoroModel.dir.appendingPathComponent("voices.bin"), voice: voice, length: ids.count)
        let outputs = try model.run(
            withInputs: [
                "tokens": try Onnx.tensor(padded, shape: [1, padded.count]),
                "style": try Onnx.tensor(style, shape: [1, KokoroStyles.styleSize]),
                "speed": try Onnx.tensor([Float(1)], shape: [1]),
            ],
            outputNames: ["audio"],
            runOptions: nil
        )
        guard let output = outputs["audio"] else { throw SpeechFailure("Kokoro gave no output") }
        return try Onnx.floats(output)
    }
}
