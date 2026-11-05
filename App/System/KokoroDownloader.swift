import AudiopapersKit
import Foundation
import Observation
import UIKit

/// The Kokoro model download: not running, running (bytes so far, total or -1), or failed.
enum KokoroDownload: Equatable {
    case idle
    case running(done: Int64, total: Int64)
    case failed(String)
}

/// Downloads the Kokoro voice model's files with a background URLSession, so it finishes if the app
/// is left. Once they're all here, audiopapers_core checks them against their hashes and installs them.
@MainActor
@Observable
final class KokoroDownloader: NSObject {
    private static let sessionId = "com.audiopapers.ios.kokoro"

    private(set) var state = KokoroDownload.idle
    /// Bumped when a download finishes, so the screens look again.
    private(set) var installs = 0

    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var delegateBridge: DownloadDelegate?
    /// Bytes so far of each file that's downloading.
    @ObservationIgnored private var received: [String: Int64] = [:]
    @ObservationIgnored private var installing = false

    override init() {
        super.init()
        let bridge = DownloadDelegate(owner: self)
        delegateBridge = bridge
        #if os(Linux) // for scripts/typecheck-linux.sh: Linux's Foundation has no background sessions
        let configuration = URLSessionConfiguration.default
        #else
        let configuration = URLSessionConfiguration.background(withIdentifier: KokoroDownloader.sessionId)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #endif
        session = URLSession(configuration: configuration, delegate: bridge, delegateQueue: nil)
        // A download from before the app was last stopped carries on, and reports here.
        session.getAllTasks { tasks in
            if !tasks.isEmpty {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.progress(file: nil, done: 0) }
                }
            }
        }
    }

    func start() {
        let info = KokoroModel.info
        received = [:]
        try? FileManager.default.removeItem(at: KokoroModel.downloads)
        ensureDirectory(KokoroModel.downloads)
        excludeFromBackup(Core.paths.kokoroRoot)
        progress(file: nil, done: 0)
        for file in info.files {
            guard let url = URL(string: info.baseUrl + file.name) else { continue }
            let task = session.downloadTask(with: url)
            task.taskDescription = file.name
            task.resume()
        }
    }

    func cancelAndDelete(speech: Speech) {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        state = .idle
        Task {
            await speech.releaseKokoro()
            KokoroModel.delete()
            installs += 1
        }
    }

    /// Files already here count in full, including ones from before the app was last stopped.
    fileprivate func progress(file: String?, done: Int64) {
        if let file { received[file] = done }
        let files = KokoroModel.info.files
        let finished = files.filter { FileManager.default.fileExists(atPath: KokoroModel.downloads.appendingPathComponent($0.name).path) }
        let finishedBytes = finished.reduce(Int64(0)) { $0 + $1.size }
        let partialBytes = files.filter { !finished.contains($0) }.reduce(Int64(0)) { $0 + (received[$1.name] ?? 0) }
        state = .running(done: finishedBytes + partialBytes, total: files.reduce(Int64(0)) { $0 + $1.size })
    }

    /// One failed file fails the download: the others would only be thrown away.
    fileprivate func failed(_ message: String) {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        state = .failed("Couldn't download the voice: \(message)")
    }

    fileprivate func fileArrived() {
        let manager = FileManager.default
        let allHere = KokoroModel.info.files.allSatisfy { manager.fileExists(atPath: KokoroModel.downloads.appendingPathComponent($0.name).path) }
        guard allHere else {
            progress(file: nil, done: 0)
            return
        }
        guard !installing else { return }
        installing = true
        let grace = UIApplication.shared.beginBackgroundTask(withName: "Installing the voice", expirationHandler: nil)
        Task {
            defer {
                installing = false
                try? FileManager.default.removeItem(at: KokoroModel.downloads)
                UIApplication.shared.endBackgroundTask(grace)
            }
            do {
                try await Core.kokoroInstall(downloads: KokoroModel.downloads)
                state = .idle
                installs += 1
            } catch let error as CoreError {
                state = .failed("Couldn't download the voice: \(error.message)")
            } catch {
                state = .failed("Couldn't download the voice: \(error.localizedDescription)")
            }
        }
    }

    fileprivate func finishedBackgroundEvents() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }
}

/// URLSession calls this on its own queue.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private weak var owner: KokoroDownloader?

    init(owner: KokoroDownloader) { self.owner = owner }

    private func onMain(_ work: @escaping @MainActor (KokoroDownloader) -> Void) {
        DispatchQueue.main.async { [weak owner] in
            MainActor.assumeIsolated {
                if let owner { work(owner) }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let file = downloadTask.taskDescription
        onMain { $0.progress(file: file, done: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file only stays there until this returns.
        do {
            if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
                throw SpeechFailure("HTTP \(response.statusCode)")
            }
            guard let name = downloadTask.taskDescription else { throw SpeechFailure("A file had no name") }
            let kept = KokoroModel.downloads.appendingPathComponent(name)
            ensureDirectory(KokoroModel.downloads)
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.moveItem(at: location, to: kept)
            onMain { $0.fileArrived() }
        } catch {
            let message = error.localizedDescription
            onMain { $0.failed(message) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, error.code != NSURLErrorCancelled else { return }
        let message = error.localizedDescription
        onMain { $0.failed(message) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onMain { $0.finishedBackgroundEvents() }
    }
}
