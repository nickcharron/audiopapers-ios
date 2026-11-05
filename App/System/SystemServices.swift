import AudiopapersKit
import BackgroundTasks
import Foundation
import PDFKit
import Security
import UIKit
import UserNotifications

/// The Gemini key, in the Keychain: encrypted, and useless off this device. Readable once the phone
/// has been unlocked after starting up, since narration asks for it with the screen locked.
final class KeychainSecrets: SecretStore, @unchecked Sendable {
    private let service = "com.audiopapers.ios"
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    func read(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = status == errSecSuccess ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache[name] = value
        return value
    }

    func write(_ name: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        cache[name] = value
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = value?.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { Log.e("Couldn't save the key: \(status)") }
    }
}

final class LocalNotifier: Notifier, @unchecked Sendable {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func finished(key: String, title: String, text: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
}

/// Asks iOS for time to finish a job once the app has left the screen. Since iOS 26 a job started
/// by the listener can keep going with its progress shown by the system; before that, it's a short
/// grace period. Either way a job keeps running as long as narration or the microphone keep the app
/// awake.
@MainActor
final class SystemBackgroundRunner: BackgroundRunner {
    func begin(title: String, onExpire: @escaping @MainActor () -> Void) -> BackgroundLease {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let lease = ContinuedLease(title: title, onExpire: onExpire) {
            return lease
        }
        #endif
        return GraceLease(title: title, onExpire: onExpire)
    }
}

@MainActor
private final class GraceLease: BackgroundLease {
    private var task = UIBackgroundTaskIdentifier.invalid

    init(title: String, onExpire: @escaping @MainActor () -> Void) {
        task = UIApplication.shared.beginBackgroundTask(withName: title) { [weak self] in
            MainActor.assumeIsolated {
                onExpire()
                self?.finish()
            }
        }
    }

    nonisolated func update(done: Int, total: Int) {}

    nonisolated func end(success: Bool) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { finish() }
        }
    }

    private func finish() {
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
@MainActor
private final class ContinuedLease: BackgroundLease {
    private static let prefix = "com.audiopapers.ios.job."
    private var task: BGContinuedProcessingTask?
    private var progress: (done: Int, total: Int)?
    private var ended: Bool?

    init?(title: String, onExpire: @escaping @MainActor () -> Void) {
        let identifier = ContinuedLease.prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                guard let self else {
                    continued.setTaskCompleted(success: false)
                    return
                }
                continued.expirationHandler = {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            onExpire()
                            continued.setTaskCompleted(success: false)
                        }
                    }
                }
                self.task = continued
                if let ended = self.ended {
                    continued.setTaskCompleted(success: ended)
                } else if let progress = self.progress {
                    self.apply(progress)
                }
            }
        }
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Audiopapers")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.w("Couldn't ask to keep running: \(error)")
            return nil
        }
    }

    private func apply(_ progress: (done: Int, total: Int)) {
        task?.progress.totalUnitCount = Int64(progress.total)
        task?.progress.completedUnitCount = Int64(progress.done)
    }

    nonisolated func update(done: Int, total: Int) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                progress = (done, total)
                apply((done, total))
            }
        }
    }

    nonisolated func end(success: Bool) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                ended = success
                task?.setTaskCompleted(success: success)
                task = nil
            }
        }
    }
}
#endif

/// Crops a figure/table/equation out of a paper's PDF so the describe prompt can show it. Gemini
/// ingestion records each item's page and box (figures.json `box_2d`) but no image; PDFKit draws the
/// page and this cuts the box out, cached as extracted/figures/<figure_id>.png in the paper's folder.
enum FigureCropper {
    // Render at 2x the PDF's 72-dpi point size: sharp enough to read a figure on a phone.
    private static let renderScale: CGFloat = 2
    // Gemini's boxes can be a little tight; pad by this fraction of the page on each side.
    private static let padFraction: CGFloat = 0.01

    static func crop(paperId: String, figureId: String) async throws -> URL? {
        let paperDir = Core.paperDir(paperId)
        let out = paperDir.appendingPathComponent("extracted/figures/\(figureId).png")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let entry = try await Core.figureEntry(paperId, figureId),
              let pageNumber = entry.page,
              let box = entry.box2d, box.count == 4 else { return nil }
        let pdf = paperDir.appendingPathComponent("source.pdf")
        return try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: pdf),
                  pageNumber >= 1, pageNumber <= document.pageCount,
                  let page = document.page(at: pageNumber - 1) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let size = CGSize(width: bounds.width * renderScale, height: bounds.height * renderScale)
            guard let full = page.thumbnail(of: size, for: .mediaBox).cgImage else { return nil }
            let width = CGFloat(full.width)
            let height = CGFloat(full.height)
            let left = max(0, min(width - 1, (CGFloat(box[1]) / 1000 - padFraction) * width))
            let top = max(0, min(height - 1, (CGFloat(box[0]) / 1000 - padFraction) * height))
            let right = max(left + 1, min(width, (CGFloat(box[3]) / 1000 + padFraction) * width))
            let bottom = max(top + 1, min(height, (CGFloat(box[2]) / 1000 + padFraction) * height))
            guard let cropped = full.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)),
                  let data = UIImage(cgImage: cropped).pngData() else { return nil }
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: out)
            return out
        }.value
    }
}
