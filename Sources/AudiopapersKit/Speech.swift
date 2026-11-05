import Foundation

private let phonePartChars = 3_800
private let wavHeaderBytes: Int64 = 44

/// Something that went wrong making speech, in words for the listener.
public struct SpeechFailure: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Which voice to render with.
public enum Voice: Equatable, Sendable {
    /// The phone's text-to-speech, in the voice picked in Settings (or the system's default).
    case phone
    case gemini(name: String, model: String?)
    case kokoro(KokoroVoice)

    /// Identifies the voice in saved-audio records (see OfflineAudio).
    public var label: String {
        switch self {
        case .phone: return Settings.phoneVoice.map { "phone:\($0)" } ?? "phone"
        case .gemini(let name, let model): return "gemini:\(name):\(model ?? "")"
        case .kokoro(let voice): return "kokoro:\(voice.name)"
        }
    }

    public var isKokoro: Bool {
        if case .kokoro = self { return true }
        return false
    }

    public var isGemini: Bool {
        if case .gemini = self { return true }
        return false
    }

    /// The voice chosen in Settings for the paper's own text.
    public static func current() -> Voice { of(Settings.voiceEngine) }

    /// The voice chosen for what's made on the spot: figure descriptions and answers.
    public static func live() -> Voice { of(Settings.liveVoiceEngine) }

    /// The voice chosen for reading a paper's summary aloud.
    public static func summary() -> Voice { of(Settings.summaryVoiceEngine) }

    // The phone voice if that's Kokoro but its model isn't downloaded (yet, or any more).
    private static func of(_ engine: VoiceEngine) -> Voice {
        switch engine {
        case .gemini: return .gemini(name: Settings.geminiVoice, model: Settings.geminiTtsModel)
        case .kokoro:
            if KokoroModel.isInstalled, let voice = Core.catalog.kokoroVoice(named: Settings.kokoroVoice) { return .kokoro(voice) }
            return .phone
        case .phone: return .phone
        }
    }
}

/// The on-device Kokoro voice model's files: downloaded once from sherpa-onnx's GitHub release (no
/// server of ours involved), checked against a known SHA-256, and unpacked into the app's private
/// storage by audiopapers_core.
public enum KokoroModel {
    public static var info: KokoroModelInfo { Core.catalog.kokoroModel }
    public static var dir: URL { Core.paths.kokoroRoot.appendingPathComponent(info.name) }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("ready").path) }

    public static func delete() {
        try? FileManager.default.removeItem(at: Core.paths.kokoroRoot)
    }
}

/// The phone's own text-to-speech, writing `text` to an audio file.
public protocol PhoneSynthesizer: AnyObject {
    func render(_ text: String, voiceIdentifier: String?, to url: URL) async throws
}

/// The Kokoro model, writing `text` to an audio file.
public protocol KokoroSynthesizer: AnyObject {
    func synthesize(_ text: String, voice: KokoroVoice, to url: URL) async throws
    /// Frees the model's memory (about the size of the model), e.g. once it's deleted.
    func release() async
}

/// Turns text into audio files, with the phone's built-in text-to-speech (offline, free), a Gemini
/// voice (more natural, needs a connection, uses the user's Gemini quota), or the on-device Kokoro
/// voice (natural, offline, free, but slower to render). Files are played through the player (see
/// ReadingEngine) rather than spoken directly, so lock-screen controls, speed and pause/resume work
/// the same either way.
///
/// Files are cached by name, voice and a hash of the text, so each passage is rendered once per
/// voice. A Gemini response with no audio puts just that passage in the phone voice. If a Gemini
/// voice fails otherwise -- a quota limit, no connection, a key problem -- this falls back to the
/// phone voice until `resumeGemini`, and reports why through `onGeminiUnavailable`.
@MainActor
public final class Speech {
    private let phone: PhoneSynthesizer
    private let kokoro: KokoroSynthesizer

    /// Set after a Gemini voice failure; cleared by `resumeGemini` (e.g. a new session).
    private var geminiPaused = false
    public var onGeminiUnavailable: ((String) -> Void)?

    public init(phone: PhoneSynthesizer, kokoro: KokoroSynthesizer) {
        self.phone = phone
        self.kokoro = kokoro
    }

    public func resumeGemini() {
        geminiPaused = false
    }

    /// The files that speak `text`, in order, rendering any not already cached in `dir`. `onPart`
    /// gets each file as soon as it's ready -- the Kokoro voice renders a passage in parts, so
    /// playback can start on the first while the rest are made. With `fallback` false, a Gemini
    /// voice failure is thrown (as CoreError) instead of falling back to the phone voice -- for
    /// downloads, which should be one voice.
    @discardableResult
    public func render(
        _ text: String,
        dir: URL,
        name: String,
        voice: Voice? = nil,
        fallback: Bool = true,
        onPart: (URL) async throws -> Void = { _ in }
    ) async throws -> [URL] {
        ensureDirectory(dir)
        excludeFromBackup(dir)
        let voice = voice ?? Voice.current()
        let hash = stableHash(text)
        if case .kokoro(let kokoroVoice) = voice {
            return try await renderWithKokoro(text, dir: dir, stem: "\(name)-k-\(kokoroVoice.name)-\(hash)", voice: kokoroVoice, onPart: onPart)
        }
        let files = try await renderWhole(text, dir: dir, name: name, hash: hash, voice: voice, fallback: fallback)
        for file in files { try await onPart(file) }
        return files
    }

    private func renderWhole(_ text: String, dir: URL, name: String, hash: String, voice: Voice, fallback: Bool) async throws -> [URL] {
        if case .gemini(let geminiName, let model) = voice {
            let file = dir.appendingPathComponent("\(name)-g-\(geminiName)-\(hash).wav")
            // Saved (e.g. downloaded) Gemini audio plays even while Gemini is paused: only
            // passages not yet rendered need a working Gemini voice.
            if fileSize(file) > 0 { return [file] }
            if !geminiPaused {
                let temporary = temporaryFile(for: file)
                defer { try? FileManager.default.removeItem(at: temporary) } // clears a failed or cancelled render
                do {
                    try await Core.speak(text, out: temporary, voice: geminiName, ttsModel: model)
                    try moveIntoPlace(temporary, file)
                    return [file]
                } catch let error as CoreError {
                    // Gemini now and then returns no audio for one passage while the next ones
                    // work, so only this passage is read by the phone voice -- downloads included,
                    // or one stubborn paragraph would stop every download of the paper.
                    if error.type == "no_audio" {
                        Log.w("No Gemini audio for \(name), using the phone voice for it: \(error.message)")
                        return try await renderWithPhone(text, dir: dir, name: name, hash: hash)
                    }
                    if !fallback { throw error }
                    geminiPaused = true
                    onGeminiUnavailable?("The Gemini voice stopped working, so the phone's voice is reading for now. \(error.friendlyMessage)")
                }
            }
        }
        return try await renderWithPhone(text, dir: dir, name: name, hash: hash)
    }

    /// The text each of `render`'s files speaks, in order -- e.g. to tell how far through a passage
    /// playback is. (A Gemini voice that falls back to the phone voice splits as the phone voice
    /// does instead.)
    public func partTexts(_ text: String, voice: Voice) async throws -> [String] {
        switch voice {
        case .kokoro: return try await Core.kokoroParts(text)
        case .gemini: return [text]
        case .phone: return try await Core.splitSpeech(text, limit: phonePartChars)
        }
    }

    private func renderWithKokoro(_ text: String, dir: URL, stem: String, voice: KokoroVoice, onPart: (URL) async throws -> Void) async throws -> [URL] {
        var files: [URL] = []
        for (i, part) in try await Core.kokoroParts(text).enumerated() {
            let file = dir.appendingPathComponent("\(stem)-\(i).wav")
            // More than a bare WAV header, or it's not really a recording.
            if fileSize(file) <= wavHeaderBytes {
                let temporary = temporaryFile(for: file)
                defer { try? FileManager.default.removeItem(at: temporary) }
                do {
                    try await kokoro.synthesize(part, voice: voice, to: temporary)
                    try moveIntoPlace(temporary, file)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.e("Kokoro failed on \(stem)-\(i): \(error)")
                    throw SpeechFailure("The on-device voice couldn't read this part")
                }
            }
            try await onPart(file)
            files.append(file)
        }
        return files
    }

    private func renderWithPhone(_ text: String, dir: URL, name: String, hash: String) async throws -> [URL] {
        let picked = Settings.phoneVoice
        // A picked voice is part of the file name, so changing it renders afresh.
        let stem = picked.map { "\(name)-p-\(stableHash($0))-\(hash)" } ?? "\(name)-p-\(hash)"
        var files: [URL] = []
        for (i, part) in try await Core.splitSpeech(text, limit: phonePartChars).enumerated() {
            let file = dir.appendingPathComponent("\(stem)-\(i).wav")
            if fileSize(file) == 0 {
                let temporary = temporaryFile(for: file)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await phone.render(part, voiceIdentifier: picked, to: temporary)
                try moveIntoPlace(temporary, file)
            }
            files.append(file)
        }
        return files
    }

    /// Frees the Kokoro model's memory.
    public func releaseKokoro() async {
        await kokoro.release()
        try? await Core.kokoroRelease()
    }
}
