import Foundation

/// One of Kokoro v1.0's English voices: `id` is its speaker id in the model, `british` picks the
/// British-English pronunciation the voice was made for.
public struct KokoroVoice: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var id: Int
    public var label: String
    public var british: Bool
}

public struct GeminiVoice: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var description: String
    public var id: String { name }
}

public struct KokoroModelInfo: Codable, Equatable, Sendable {
    public var name: String
    public var downloadMb: Int
    public var url: String
    public var sha256: String
    public var keep: [String]
}

public struct ListenTimes: Codable, Equatable, Sendable {
    public var noSpeechMs: Int64
    public var endSilenceMs: Int64
    public var maxMs: Int64
}

/// The data both phone apps share, from audiopapers_core/catalog.json: read straight from the
/// bundled package, so it's there without waiting on Python.
public struct Catalog: Codable, Equatable, Sendable {
    public var geminiVoices: [GeminiVoice]
    public var defaultGeminiVoice: String
    public var kokoroVoices: [KokoroVoice]
    public var defaultKokoroVoice: String
    public var kokoroModel: KokoroModelInfo
    public var wakeSensitivity: [String: Float]
    public var listenModes: [String: ListenTimes]

    public func kokoroVoice(named name: String) -> KokoroVoice? {
        kokoroVoices.first { $0.name == name }
    }

    static func load(from packageDirectory: URL) throws -> Catalog {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Catalog.self, from: Data(contentsOf: packageDirectory.appendingPathComponent("catalog.json")))
    }
}
