import Foundation
import Observation

/// "Done" notifications for long background jobs -- adding a paper, preparing its audio -- so they
/// can run while the phone is put away. Posted from the phone itself when the job ends; nothing goes
/// through a server.
public protocol Notifier: AnyObject {
    /// Shows (or replaces) the notification for `key`, so a later result for the same job replaces
    /// an earlier one instead of piling up.
    func finished(key: String, title: String, text: String)
}

/// What the operating system lets a job do once the app has left the screen.
public protocol BackgroundLease: AnyObject {
    func update(done: Int, total: Int)
    func end(success: Bool)
}

@MainActor
public protocol BackgroundRunner: AnyObject {
    /// Asks to keep running. `onExpire` is called if that time runs out.
    func begin(title: String, onExpire: @escaping @MainActor () -> Void) -> BackgroundLease
}

/// Records that a paper's audio was fully downloaded, and in which voice: the saved files only help
/// offline listening in the voice they were made with.
public enum OfflineAudio {
    private static func marker(_ paperId: String) -> URL { Core.ttsDir(paperId).appendingPathComponent("offline.json") }

    public static func markReady(_ paperId: String, voiceLabel: String, segments: Int) {
        let file = marker(paperId)
        ensureDirectory(file.deletingLastPathComponent())
        let data = try? JSONSerialization.data(withJSONObject: ["voice": voiceLabel, "segments": segments] as [String: Any])
        try? data?.write(to: file)
    }

    /// The voice label a complete download was made with, or nil if there isn't one.
    public static func readyVoice(_ paperId: String) -> String? {
        guard let data = try? Data(contentsOf: marker(paperId)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["voice"] as? String
    }
}

/// A paper's offline audio job.
public enum AudioJob: Equatable, Sendable {
    case running(done: Int, total: Int)
    case failed(String)
}

public enum IngestState: Equatable, Sendable {
    case idle
    /// `totalPages` is 0 until Gemini has finished the first chunk and reported the count.
    case ingesting(fileName: String, pagesDone: Int, totalPages: Int)
    case failed(String)
}

/// Long jobs: ingesting a PDF, and rendering a paper's audio ahead of time. They keep going for as
/// long as iOS lets the app run, which is as long as it's on screen or playing or listening, and
/// otherwise however long BackgroundRunner can get. Audio that's already saved is skipped, so a
/// download that's stopped can pick up again; one that was running when the app was stopped does,
/// next time it opens.
@MainActor
@Observable
public final class BackgroundJobs {
    public private(set) var audioJobs: [String: AudioJob] = [:]
    public private(set) var ingestState: IngestState = .idle
    /// Bumped when a job's finished something the home screen should show.
    public private(set) var finishedCount = 0

    @ObservationIgnored private let speech: Speech
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let runner: BackgroundRunner
    @ObservationIgnored private var audioTasks: [String: Task<Void, Never>] = [:]

    private static let pendingKey = "pending_audio_downloads"

    public init(speech: Speech, notifier: Notifier, runner: BackgroundRunner) {
        self.speech = speech
        self.notifier = notifier
        self.runner = runner
    }

    private var pendingDownloads: [String] {
        get { Settings.defaults.stringArray(forKey: BackgroundJobs.pendingKey) ?? [] }
        set { Settings.defaults.set(newValue, forKey: BackgroundJobs.pendingKey) }
    }

    /// Carries on with downloads the app was stopped in the middle of.
    public func resumePending() {
        for paperId in pendingDownloads where audioTasks[paperId] == nil {
            downloadAudio(paperId)
        }
    }

    /// Ingests one PDF already copied somewhere the app can read, then deletes it. Reports pages
    /// done as it goes, and hands the new paper's id to `onIngested`.
    public func ingest(pdf: URL, fileName: String, downloadAudio: Bool, onIngested: @escaping @MainActor (String) -> Void) {
        ingestState = .ingesting(fileName: fileName, pagesDone: 0, totalPages: 0)
        let lease = runner.begin(title: "Adding \(fileName)") {}
        Task {
            defer { try? FileManager.default.removeItem(at: pdf) }
            do {
                let result = try await Core.ingest(pdf: pdf) { [weak self] done, total in
                    Task { @MainActor [weak self] in
                        lease.update(done: done, total: total)
                        if case .ingesting = self?.ingestState {
                            self?.ingestState = .ingesting(fileName: fileName, pagesDone: done, totalPages: total)
                        }
                    }
                }
                lease.end(success: true)
                notifier.finished(key: "ingest:\(fileName)", title: "Paper added", text: "\"\(result.paperId)\" is ready.")
                ingestState = .idle
                finishedCount += 1
                // Downloading the audio, if asked for, runs right after the ingest succeeds.
                if downloadAudio { self.downloadAudio(result.paperId) }
                onIngested(result.paperId)
            } catch let error as CoreError {
                lease.end(success: false)
                notifier.finished(key: "ingest:\(fileName)", title: "Couldn't add \(fileName)", text: error.friendlyMessage)
                ingestState = .failed(error.friendlyMessage)
            } catch {
                lease.end(success: false)
                ingestState = .idle
            }
        }
    }

    public func dismissIngestError() {
        ingestState = .idle
    }

    /// Renders every paragraph of a paper in the current voice ahead of time, so it can be listened
    /// to offline -- useful with a Gemini voice, which otherwise needs a connection the first time
    /// each paragraph plays, and required with the Kokoro voice, which renders too slowly to keep up
    /// while listening. A Gemini failure (e.g. the daily limit) ends it with a message saying how far
    /// it got.
    public func downloadAudio(_ paperId: String) {
        audioTasks[paperId]?.cancel()
        if !pendingDownloads.contains(paperId) { pendingDownloads.append(paperId) }
        audioJobs[paperId] = .running(done: 0, total: 0)
        let voice = Voice.current()
        let lease = runner.begin(title: "Preparing audio for \(paperId)") { [weak self] in
            // Out of time, but it isn't finished with: it picks up when the app next opens.
            self?.audioTasks[paperId]?.cancel()
            self?.audioTasks[paperId] = nil
        }
        audioTasks[paperId] = Task {
            var succeeded = false
            defer { lease.end(success: succeeded) }
            do {
                let segments = try await Core.narration(paperId)
                for (i, segment) in segments.enumerated() {
                    try Task.checkCancellation()
                    audioJobs[paperId] = .running(done: i, total: segments.count)
                    lease.update(done: i, total: segments.count)
                    do {
                        try await speech.render(segment.text, dir: Core.ttsDir(paperId), name: segment.audioId, voice: voice, fallback: false)
                    } catch let error as CoreError {
                        stopped(paperId, done: i, total: segments.count, reason: error.friendlyMessage)
                        return
                    } catch let error as SpeechFailure {
                        stopped(paperId, done: i, total: segments.count, reason: error.message)
                        return
                    }
                }
                OfflineAudio.markReady(paperId, voiceLabel: voice.label, segments: segments.count)
                forget(paperId)
                audioJobs[paperId] = nil
                finishedCount += 1
                succeeded = true
                notifier.finished(key: "audio:\(paperId)", title: "Audio ready", text: "\"\(paperId)\" is ready to listen to.")
            } catch let error as CoreError {
                forget(paperId)
                audioJobs[paperId] = .failed(error.friendlyMessage)
            } catch {
                // Cancelled. By the listener (see cancelAudio), or out of background time.
            }
        }
    }

    private func stopped(_ paperId: String, done: Int, total: Int, reason: String) {
        let message = "Saved \(done) of \(total) paragraphs, then stopped. \(reason)"
        forget(paperId)
        audioJobs[paperId] = .failed(message)
        notifier.finished(key: "audio:\(paperId)", title: "Audio for \"\(paperId)\" stopped", text: message)
    }

    private func forget(_ paperId: String) {
        pendingDownloads.removeAll { $0 == paperId }
        audioTasks[paperId] = nil
    }

    public func cancelAudio(_ paperId: String) {
        audioTasks[paperId]?.cancel()
        forget(paperId)
        audioJobs[paperId] = nil
    }
}
