import Foundation

#if canImport(os)
import os

private let logger = Logger(subsystem: "com.audiopapers.ios", category: "audiopapers")

public enum Log {
    public static func d(_ message: String) { logger.debug("\(message, privacy: .public)") }
    public static func w(_ message: String) { logger.warning("\(message, privacy: .public)") }
    public static func e(_ message: String) { logger.error("\(message, privacy: .public)") }
}
#else
public enum Log {
    public static func d(_ message: String) {}
    public static func w(_ message: String) {}
    public static func e(_ message: String) { print("audiopapers: \(message)") }
}
#endif

/// FIFO mutual exclusion across suspension points: cancelling a task doesn't stop a call into
/// the core that's already running, so without this a slow one could land after its replacement.
public actor AsyncLock {
    private var locked = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            locked = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    public func withLock<T>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}

/// A stable 32-bit hash of some text, as hex: part of the names audio is cached under, so it must
/// come out the same on every launch, which Swift's own `hashValue` doesn't.
public func stableHash(_ text: String) -> String {
    var hash: UInt32 = 2_166_136_261
    for byte in text.utf8 {
        hash = (hash ^ UInt32(byte)) &* 16_777_619
    }
    return String(hash, radix: 16)
}

func sleepMs(_ milliseconds: Int64) async throws {
    if milliseconds > 0 {
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}

/// A file with its folders made first.
func ensureDirectory(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func fileSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

/// A rendering's temporary file, unique per render: playback and a background download can render
/// the same passage at the same time. It keeps its extension, since what writes audio can go by that.
func temporaryFile(for file: URL) -> URL {
    file.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString)-\(file.lastPathComponent)")
}

/// Moves a finished rendering into place, replacing any other render's copy.
func moveIntoPlace(_ temporary: URL, _ file: URL) throws {
    let manager = FileManager.default
    if manager.fileExists(atPath: file.path) {
        try manager.removeItem(at: file)
    }
    try manager.moveItem(at: temporary, to: file)
}

/// Rendered speech can be made again, so it's no use taking up someone's backup.
func excludeFromBackup(_ directory: URL) {
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
}
