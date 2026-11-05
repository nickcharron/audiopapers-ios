import CPythonBridge
import Foundation

/// A failure reported by audiopapers_core. `type` is one of "auth", "quota", "ai", "network",
/// "not_found", "conflict", "invalid", "internal" (see bridge.py), or "no_key" when no Gemini key
/// has been saved yet. For "quota", `scope` says which limit was hit ("minute", "day", or nil if
/// Gemini didn't say) and `retryAfterS` how long it asked to wait.
public struct CoreError: Error, Equatable, LocalizedError, Sendable {
    public var type: String
    public var message: String
    public var scope: String?
    public var retryAfterS: Double?

    public init(type: String, message: String, scope: String? = nil, retryAfterS: Double? = nil) {
        self.type = type
        self.message = message
        self.scope = scope
        self.retryAfterS = retryAfterS
    }

    public var errorDescription: String? { message }

    /// Says what happened and what to do about it, in terms a listener can act on.
    public var friendlyMessage: String {
        switch type {
        case "no_key": return "Add your free Gemini API key in Settings first."
        case "auth": return "Gemini didn't accept your API key. It may have been mistyped or deleted. Check it in Settings."
        case "quota": return quotaMessage()
        case "network": return "Couldn't reach Gemini. Check your connection and try again."
        default: return message
        }
    }

    private func quotaMessage() -> String {
        switch scope {
        case "minute":
            let wait = retryAfterS.map { "about \(max(Int($0.rounded()), 1)) seconds" } ?? "a minute"
            return "Your free Gemini key allows only a few requests per minute. Wait \(wait) and try again."
        case "day":
            return "You've used today's free Gemini requests. They reset at midnight Pacific time, " +
                "\(CoreError.untilPacificMidnight()) from now. Papers you've already added still play."
        default:
            return "Gemini says your key has reached a usage limit. Wait a minute and try again. If it keeps " +
                "happening, today's free requests are used up; they reset at midnight Pacific time, " +
                "\(CoreError.untilPacificMidnight()) from now."
        }
    }

    static func untilPacificMidnight(from now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let minutes = Int(tomorrow.timeIntervalSince(now) / 60)
        return minutes >= 90 ? "about \((minutes + 30) / 60) hours" : "about \(minutes) minutes"
    }
}

/// Where everything the core needs lives.
public struct CorePaths: Sendable {
    /// The bundled Python's home; nil to use this machine's own Python.
    public var pythonHome: String?
    /// The folder holding the audiopapers_core package.
    public var appPath: URL
    /// Somewhere writable for compiled bytecode, since an app bundle isn't.
    public var pycachePrefix: String?
    /// The folder for papers: <dataDir>/<paper_id>/.
    public var dataDir: URL
    /// The folder for the downloaded Kokoro voice.
    public var kokoroRoot: URL
    /// g2p_en's weights, for words Kokoro's word list doesn't have.
    public var g2pCheckpoint: URL
    /// CA certificates for Python's HTTPS, since embedded Python can't reach the system's.
    public var caFile: URL?

    public init(pythonHome: String?, appPath: URL, pycachePrefix: String?, dataDir: URL, kokoroRoot: URL, g2pCheckpoint: URL, caFile: URL?) {
        self.pythonHome = pythonHome
        self.appPath = appPath
        self.pycachePrefix = pycachePrefix
        self.dataDir = dataDir
        self.kokoroRoot = kokoroRoot
        self.g2pCheckpoint = g2pCheckpoint
        self.caFile = caFile
    }
}

private final class ProgressBox {
    let onProgress: @Sendable (Int, Int) -> Void
    init(_ onProgress: @escaping @Sendable (Int, Int) -> Void) { self.onProgress = onProgress }
}

private struct Envelope<T: Decodable>: Decodable {
    struct Failure: Decodable {
        var type: String
        var message: String
        var scope: String?
        var retryAfterS: Double?
    }

    var ok: Bool
    var result: T?
    var error: Failure?
}

/// Decodes anything, for calls whose result doesn't matter.
private struct Ignored: Decodable {
    init(from decoder: Decoder) throws {}
}

/// The app's only way into audiopapers_core, the Python package that does all the paper work
/// (ingest, narration text, the reading session, questions, notes, summaries): the same code the
/// laptop tests run, embedded through the C bridge. Each call runs off the main thread and returns
/// the bridge's JSON decoded into Models.swift types.
///
/// Papers live in the app's private storage: <dataDir>/<paper_id>/.
public enum Core {
    public private(set) static var paths: CorePaths!
    public private(set) static var catalog: Catalog!
    private static let queue = DispatchQueue(label: "audiopapers.core", qos: .userInitiated, attributes: .concurrent)
    private static var started = false

    /// Starts Python, once. Takes a moment, so it's not for the main thread.
    public static func start(_ paths: CorePaths) throws {
        if started { return }
        self.paths = paths
        catalog = try Catalog.load(from: paths.appPath.appendingPathComponent("audiopapers_core"))
        ensureDirectory(paths.dataDir)
        if let caFile = paths.caFile {
            setenv("SSL_CERT_FILE", caFile.path, 1)
        }
        var error: UnsafeMutablePointer<CChar>?
        let status = ap_python_start(paths.pythonHome, paths.appPath.path, paths.pycachePrefix, &error)
        if status != 0 {
            let message = error.map { String(cString: $0) } ?? "Couldn't start Python"
            ap_python_free(error)
            throw CoreError(type: "internal", message: message)
        }
        started = true
    }

    public static func paperDir(_ paperId: String) -> URL { paths.dataDir.appendingPathComponent(paperId) }

    /// Where a paper's rendered speech is saved (see Speech).
    public static func ttsDir(_ paperId: String) -> URL { paperDir(paperId).appendingPathComponent("tts") }

    // MARK: - Papers

    public static func listPapers() async throws -> [PaperSummary] { try await call("list_papers", [dir]) }
    public static func paperDetail(_ paperId: String) async throws -> PaperDetail { try await call("paper_detail", [dir, paperId]) }
    public static func deletePaper(_ paperId: String) async throws { try await run("delete_paper", [dir, paperId]) }
    public static func renamePaper(_ paperId: String, _ newName: String) async throws -> RenamedPaper {
        try await call("rename_paper", [dir, paperId, newName])
    }
    public static func clearPaper(_ paperId: String) async throws -> SessionView { try await call("clear_paper", [dir, paperId]) }
    public static func markRead(_ paperId: String) async throws -> SessionView { try await call("mark_read", [dir, paperId]) }

    public static func sessionAction(_ paperId: String, _ action: String) async throws -> SessionView {
        // Only "describe_yes" calls Gemini, but every action takes the key the same way.
        let key = Settings.geminiKey
        if action == "describe_yes" && key == nil { throw missingKey() }
        return try await call("session_action", [dir, paperId, action, key ?? "", Settings.geminiModel])
    }

    public static func seek(_ paperId: String, _ sectionIndex: Int) async throws -> SessionView {
        try await call("seek", [dir, paperId, sectionIndex])
    }

    public static func narration(_ paperId: String) async throws -> [NarrationSegment] { try await call("narration", [dir, paperId]) }
    public static func figureEntry(_ paperId: String, _ figureId: String) async throws -> FigureEntry? {
        try await callOptional("figure_entry", [dir, paperId, figureId])
    }

    /// `followUpOf` is the answerId of the answer this question follows up on, so the earlier
    /// questions and answers go along as context.
    public static func answer(_ paperId: String, _ question: String, followUpOf: String? = nil) async throws -> AnswerResult {
        try await call("answer", [dir, paperId, question, requireKey(), Settings.geminiModel, followUpOf])
    }

    public static func addNote(_ paperId: String, _ text: String) async throws -> Note { try await call("add_note", [dir, paperId, text]) }
    public static func deleteLastNote(_ paperId: String) async throws -> Note? { try await callOptional("delete_last_note", [dir, paperId]) }

    /// What something said to Albert asks for. Spends a Gemini request only if the fixed phrases
    /// don't cover it and there's a key.
    public static func interpretCommand(_ paperId: String?, _ text: String, screen: String, answering: Bool) async throws -> VoiceCommand {
        try await call("interpret_command", [dir, paperId, text, screen, answering, Settings.geminiKey, Settings.geminiRouterModel])
    }

    public static func figureDescription(_ paperId: String, _ figureId: String) async throws -> FigureDescription {
        try await call("figure_description", [dir, paperId, figureId, requireKey(), Settings.geminiModel])
    }

    public static func spokenPosition(_ paperId: String) async throws -> String { try await call("spoken_position", [dir, paperId]) }
    public static func spokenNotes(_ paperId: String) async throws -> String { try await call("spoken_notes", [dir, paperId]) }
    public static func spokenPapers() async throws -> String { try await call("spoken_papers", [dir]) }
    public static func recap(_ paperId: String) async throws -> String { try await call("recap", [dir, paperId, requireKey(), Settings.geminiModel]) }

    public static func getSummary(_ paperId: String) async throws -> String? { try await callOptional("get_summary", [dir, paperId]) }
    public static func generateSummary(_ paperId: String) async throws -> String {
        try await call("generate_summary", [dir, paperId, requireKey(), Settings.geminiModel])
    }

    /// Reads `text` aloud with a Gemini voice into `out` (a WAV file).
    public static func speak(_ text: String, out: URL, voice: String, ttsModel: String?) async throws {
        try await run("speak", [text, out.path, requireKey(), voice, ttsModel])
    }

    /// Checks a key (and optional model) before saving it; throws CoreError if bad.
    public static func checkKey(_ key: String, model: String?) async throws {
        try await run("check_key", [key, model])
    }

    public static func ingest(pdf: URL, onProgress: @escaping @Sendable (Int, Int) -> Void) async throws -> IngestResult {
        let data = try await raw(
            "ingest",
            [pdf.path, dir, requireKey(), Settings.geminiModel],
            kwargs: ["describe_figures": Settings.describeFiguresOnIngest],
            progress: onProgress
        )
        return try decode(data)
    }

    // MARK: - Text for the app

    public static func summaryBlocks(_ markdown: String) async throws -> [SummaryBlock] { try await call("summary_blocks", [markdown]) }
    public static func summarySpeechText(_ markdown: String) async throws -> String { try await call("summary_speech_text", [markdown]) }
    public static func splitSpeech(_ text: String, limit: Int) async throws -> [String] { try await call("split_speech", [text, limit]) }
    public static func kokoroParts(_ text: String) async throws -> [String] { try await call("kokoro_parts", [text]) }
    public static func yesOrNo(_ text: String?) async throws -> Bool? { try await callOptional("yes_or_no", [text]) }
    public static func pdfSearchQueries(_ paragraph: String) async throws -> [String] { try await call("pdf_search_queries", [paragraph]) }

    // MARK: - The Kokoro voice

    public static func kokoroTokens(_ text: String, british: Bool, modelDir: URL) async throws -> [[Int64]] {
        try await call("kokoro_tokens", [text, british, modelDir.path, paths.g2pCheckpoint.path])
    }

    public static func kokoroRelease() async throws { try await run("kokoro_release", []) }

    public static func kokoroInstall(archive: URL) async throws {
        try await run("kokoro_install", [archive.path, paths.kokoroRoot.path])
    }

    // MARK: - Calling Python

    private static var dir: String { paths.dataDir.path }

    private static func requireKey() throws -> String {
        guard let key = Settings.geminiKey else { throw missingKey() }
        return key
    }

    private static func missingKey() -> CoreError {
        CoreError(type: "no_key", message: "Add your Gemini API key in Settings first.")
    }

    private static func call<T: Decodable>(_ function: String, _ args: [Any?]) async throws -> T {
        try decode(try await raw(function, args))
    }

    private static func callOptional<T: Decodable>(_ function: String, _ args: [Any?]) async throws -> T? {
        try decodeOptional(try await raw(function, args))
    }

    private static func run(_ function: String, _ args: [Any?]) async throws {
        let _: Ignored? = try decodeOptional(try await raw(function, args))
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        guard let value: T = try decodeOptional(data) else {
            throw CoreError(type: "internal", message: "audiopapers_core returned nothing where something was expected")
        }
        return value
    }

    private static func decodeOptional<T: Decodable>(_ data: Data) throws -> T? {
        let envelope = try decoder().decode(Envelope<T>.self, from: data)
        if envelope.ok { return envelope.result }
        let failure = envelope.error ?? .init(type: "internal", message: "audiopapers_core failed without saying why")
        if failure.type == "internal" {
            Log.e("audiopapers_core failed:\n\(failure.message)")
        } else {
            Log.w("\(failure.type): \(failure.message)")
        }
        throw CoreError(type: failure.type, message: failure.message, scope: failure.scope, retryAfterS: failure.retryAfterS)
    }

    private static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs one bridge call on a background thread. Cancelling the caller can't stop a call that's
    /// already in Python, so a cancelled caller just doesn't see its result.
    private static func raw(
        _ function: String,
        _ args: [Any?],
        kwargs: [String: Any]? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Data {
        let argsJson = json(args.map { $0 ?? NSNull() })
        let kwargsJson = kwargs.map(json)
        let data: Data = await withCheckedContinuation { continuation in
            queue.async {
                let box = progress.map(ProgressBox.init)
                let context = box.map { Unmanaged.passUnretained($0).toOpaque() }
                let callback: ap_progress_fn? = box == nil ? nil : { context, done, total in
                    guard let context else { return }
                    Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue().onProgress(done, total)
                }
                let output: UnsafeMutablePointer<CChar>? = withExtendedLifetime(box) {
                    kwargsJson.withOptionalCString { kwargsPointer in
                        ap_python_call(function, argsJson, kwargsPointer, callback, context)
                    }
                }
                defer { ap_python_free(output) }
                continuation.resume(returning: output.map { Data(String(cString: $0).utf8) } ?? Data())
            }
        }
        try Task.checkCancellation()
        return data
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        switch self {
        case .some(let text): return text.withCString(body)
        case .none: return body(nil)
        }
    }
}
