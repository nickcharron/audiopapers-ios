import Foundation
import Observation

public enum PaperListState: Equatable, Sendable {
    case loading
    case loaded([PaperSummary])
    case error(String)
}

/// A paper's offline audio, as the home screen shows it.
public enum AudioStatus: Equatable, Sendable {
    case downloading(done: Int, total: Int)
    case ready
    case failed(String)
}

/// Backs the home screen: the resume list, ingesting a picked PDF (see BackgroundJobs), and the
/// Gemini key settings. Everything runs on the phone through audiopapers_core (Core); there's no
/// server.
@MainActor
@Observable
public final class HomeModel {
    public private(set) var papers: PaperListState = .loading
    /// A failed Remove/Clear/Rename from the per-paper menu -- one shared slot, since only one menu
    /// or dialog can be open at a time.
    public private(set) var actionFailure: String?
    /// Whether a Gemini key is saved -- needed to add papers and to ask/describe.
    public private(set) var hasKey = false
    /// The reading voice in effect. The Kokoro voice is too slow to render while listening, so with
    /// it a paper's audio has to be prepared (downloaded) before it can be opened.
    public private(set) var voice: Voice = .phone
    private var readyPapers: Set<String> = []

    @ObservationIgnored public let jobs: BackgroundJobs

    public init(jobs: BackgroundJobs) {
        self.jobs = jobs
    }

    /// Also re-reads whether a key is saved and which voice is chosen, since those are set on other
    /// screens.
    public func refresh() {
        hasKey = Settings.geminiKey != nil
        voice = Voice.current()
        Task {
            do {
                let list = try await Core.listPapers()
                let label = voice.label
                readyPapers = Set(list.map(\.paperId).filter { OfflineAudio.readyVoice($0) == label })
                papers = .loaded(list)
            } catch let error as CoreError {
                papers = .error(error.friendlyMessage)
            } catch {}
        }
    }

    public var prepareFirst: Bool { voice.isKokoro }

    public func audioStatus(_ paperId: String) -> AudioStatus? {
        switch jobs.audioJobs[paperId] {
        case .running(let done, let total)?: return .downloading(done: done, total: total)
        case .failed(let message)?: return readyPapers.contains(paperId) ? .ready : .failed(message)
        case nil: return readyPapers.contains(paperId) ? .ready : nil
        }
    }

    public func removePaper(_ paperId: String) { paperAction("Couldn't remove this paper") { try await Core.deletePaper(paperId) } }
    public func renamePaper(_ paperId: String, _ newName: String) { paperAction("Couldn't rename this paper") { _ = try await Core.renamePaper(paperId, newName) } }
    public func clearPaper(_ paperId: String) { paperAction("Couldn't clear this paper") { _ = try await Core.clearPaper(paperId) } }
    public func markPaperRead(_ paperId: String) { paperAction("Couldn't mark this paper read") { _ = try await Core.markRead(paperId) } }

    /// Paragraphs in a paper -- one Gemini request each when downloading a Gemini voice.
    public func paragraphCount(_ paperId: String) async -> Int? {
        try? await Core.narration(paperId).count
    }

    public func dismissActionFailure() {
        actionFailure = nil
    }

    private func paperAction(_ failure: String, _ action: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await action()
                refresh()
            } catch let error as CoreError {
                actionFailure = error.message.isEmpty ? failure : error.message
            } catch {}
        }
    }
}

public enum SummaryState: Equatable, Sendable {
    case loading
    case notGenerated
    case generating
    case ready(blocks: [SummaryBlock], speech: String)
    case error(String)
}

/// A paper has no summary until one's been generated at least once; that's shown as a "Generate"
/// button rather than an error. After that, opening it brings it up to date with every question,
/// note and figure description saved since -- no Gemini call, so it's quick.
@MainActor
@Observable
public final class SummaryModel {
    public private(set) var state: SummaryState = .loading
    @ObservationIgnored private let paperId: String
    @ObservationIgnored private let engine: ReadingEngine

    public init(paperId: String, engine: ReadingEngine) {
        self.paperId = paperId
        self.engine = engine
        Task {
            do {
                if let summary = try await Core.getSummary(paperId) {
                    state = try await SummaryModel.ready(summary)
                } else {
                    state = .notGenerated
                }
            } catch let error as CoreError {
                state = .error(error.friendlyMessage)
            } catch {}
        }
    }

    private static func ready(_ summary: String) async throws -> SummaryState {
        .ready(blocks: try await Core.summaryBlocks(summary), speech: try await Core.summarySpeechText(summary))
    }

    /// Speaking needs this paper's reading session, which the reader screen opens.
    public var canSpeak: Bool { engine.paperId == paperId }

    public func toggleSpeech() {
        if case .ready(_, let speech) = state { engine.toggleSummary(speech) }
    }

    /// Writes the paper's first summary -- a Gemini call with the user's key, so only ever
    /// user-triggered (see conversation.make_summary in audiopapers_core).
    public func generate() {
        state = .generating
        Task {
            do {
                state = try await SummaryModel.ready(try await Core.generateSummary(paperId))
            } catch let error as CoreError {
                state = .error(error.friendlyMessage)
            } catch {}
        }
    }
}

public enum KeyCheckState: Equatable, Sendable {
    case idle
    case checking
    case saved
    case failed(String)
}

/// Checks a pasted key with Gemini before saving it, so a typo shows up here rather than later in
/// the middle of adding a paper.
@MainActor
@Observable
public final class KeySetupModel {
    public private(set) var state: KeyCheckState = .idle
    public private(set) var hasKey = Settings.geminiKey != nil

    public init() {}

    public var savedModel: String { Settings.geminiModel ?? "" }

    /// A blank `key` keeps the saved one (to change just the model).
    public func saveAndCheck(key: String, model: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = trimmed.isEmpty ? Settings.geminiKey : trimmed else {
            state = .failed("Paste your Gemini API key first.")
            return
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelOrNil = trimmedModel.isEmpty ? nil : trimmedModel
        state = .checking
        Task {
            do {
                try await Core.checkKey(candidate, model: modelOrNil)
                Settings.geminiKey = candidate
                Settings.geminiModel = modelOrNil
                hasKey = true
                state = .saved
            } catch let error as CoreError {
                switch error.type {
                case "auth": state = .failed("Gemini didn't accept that key. Copy it again from AI Studio and check nothing is missing.")
                case "ai": state = .failed("Gemini doesn't recognize that model name. Leave it blank to use the default.")
                default: state = .failed(error.friendlyMessage)
                }
            } catch {}
        }
    }

    public func removeKey() {
        Settings.geminiKey = nil
        hasKey = false
        state = .idle
    }
}
