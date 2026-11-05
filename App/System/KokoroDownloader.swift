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

/// Downloads the Kokoro voice model with a background URLSession, so it finishes if the app is
/// left. Once it's here, audiopapers_core checks it against its hash and unpacks it.
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
                    MainActor.assumeIsolated { self.state = .running(done: 0, total: -1) }
                }
            }
        }
    }

    func start() {
        guard let url = URL(string: KokoroModel.info.url) else { return }
        state = .running(done: 0, total: -1)
        session.downloadTask(with: url).resume()
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

    fileprivate func progress(done: Int64, total: Int64) {
        state = .running(done: done, total: total)
    }

    fileprivate func failed(_ message: String) {
        state = .failed("Couldn't download the voice: \(message)")
    }

    fileprivate func downloaded(_ archive: URL) {
        let grace = UIApplication.shared.beginBackgroundTask(withName: "Unpacking the voice", expirationHandler: nil)
        Task {
            defer {
                try? FileManager.default.removeItem(at: archive)
                UIApplication.shared.endBackgroundTask(grace)
            }
            do {
                try await Core.kokoroInstall(archive: archive)
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
        onMain { $0.progress(done: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file only stays there until this returns.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-\(UUID().uuidString).tar.bz2")
        do {
            if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
                throw SpeechFailure("HTTP \(response.statusCode)")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            onMain { $0.downloaded(kept) }
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
