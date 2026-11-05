import Foundation
import XCTest
@testable import AudiopapersKit

private let worker = """
import struct, sys
import numpy as np, onnxruntime as ort
session = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])
name_in, name_out = session.get_inputs()[0].name, session.get_outputs()[0].name
read, write = sys.stdin.buffer.read, sys.stdout.buffer
while len(head := read(4)) == 4:
    dims = struct.unpack(f"<{struct.unpack('<I', head)[0]}I", read(4 * struct.unpack('<I', head)[0]))
    data = np.frombuffer(read(4 * int(np.prod(dims))), dtype="<f4").reshape(dims)
    out = session.run([name_out], {name_in: data})[0].astype("<f4").tobytes()
    write.write(struct.pack("<I", len(out)) + out)
    write.flush()
"""

/// A real model, run by a Python process, since ONNX Runtime has no Swift package for Linux.
private final class WorkerModel: OnnxModel {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(python: String, path: String) throws {
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", worker, path]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let more = try output.fileHandleForReading.read(upToCount: count - data.count), !more.isEmpty else {
                throw CoreError(type: "internal", message: "The model worker stopped")
            }
            data.append(more)
        }
        return data
    }

    func run(_ values: [Float], shape: [Int]) throws -> [Float] {
        var message = Data()
        for word in [UInt32(shape.count)] + shape.map({ UInt32($0) }) { withUnsafeBytes(of: word.littleEndian) { message.append(contentsOf: $0) } }
        values.withUnsafeBytes { message.append(contentsOf: $0) }
        try input.fileHandleForWriting.write(contentsOf: message)
        let size = try read(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        return try read(size).withUnsafeBytes { raw in
            (0..<(size / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}

/// The detector with the real models on recordings kept for this, against the scores of the
/// reference steps in the main repo's scripts/train_wake_word.py: the same check WakeModelTests
/// makes on a simulator with the app's own ONNX Runtime. Needs scripts/test-linux.sh's ORT_PYTHON,
/// and scripts/bootstrap.sh to have fetched the feature models.
final class RealWakeModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var fixtures: URL { root.appendingPathComponent("Tests/AppTests/wakeword") }

    private func detector() throws -> WakeDetector {
        guard let python = ProcessInfo.processInfo.environment["ORT_PYTHON"] else { throw XCTSkip("ORT_PYTHON isn't set") }
        let fetched = root.appendingPathComponent("App/Resources/Fetched")
        guard FileManager.default.fileExists(atPath: fetched.appendingPathComponent("melspectrogram.onnx").path) else {
            throw XCTSkip("Run scripts/bootstrap.sh first")
        }
        return OpenWakeWordDetector(
            melspectrogram: try WorkerModel(python: python, path: fetched.appendingPathComponent("melspectrogram.onnx").path),
            embedding: try WorkerModel(python: python, path: fetched.appendingPathComponent("embedding_model.onnx").path),
            classifier: try WorkerModel(python: python, path: root.appendingPathComponent("App/Resources/hey_albert.onnx").path)
        )
    }

    private func frames(_ name: String) throws -> [[Int16]] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("\(name).wav")).dropFirst(44)
        let samples = data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        return stride(from: 0, to: samples.count - micFrameSamples + 1, by: micFrameSamples).map { Array(samples[$0..<($0 + micFrameSamples)]) }
    }

    private func assertMatchesReference(_ name: String) throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("expected_scores.json"))) as? [String: [Double]]
        let reference = try XCTUnwrap(expected?[name])
        let detector = try detector()
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
