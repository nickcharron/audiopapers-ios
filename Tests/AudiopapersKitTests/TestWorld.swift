import Foundation
@testable import AudiopapersKit

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    func read(_ name: String) -> String? { values[name] }
    func write(_ name: String, _ value: String?) { values[name] = value }
}

/// Starts the real Python core once for the whole test run, on a scratch data folder.
enum TestWorld {
    static var root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("audiopapers-tests-\(UUID().uuidString)")

    static var coreRepo: URL {
        if let path = ProcessInfo.processInfo.environment["AUDIOPAPERS_REPO"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("audiopapers")
    }

    private static var started = false

    static func start() throws {
        if started { return }
        Settings.defaults = UserDefaults(suiteName: "audiopapers-tests-\(UUID().uuidString)")!
        Settings.secrets = MemorySecrets()
        try Core.start(CorePaths(
            pythonHome: nil,
            appPath: coreRepo,
            pycachePrefix: root.appendingPathComponent("pycache").path,
            dataDir: root.appendingPathComponent("papers"),
            kokoroRoot: root.appendingPathComponent("kokoro"),
            g2pCheckpoint: root.appendingPathComponent("none"),
            caFile: nil
        ))
        started = true
    }

    /// A small paper on disk, as ingesting one would leave it.
    @discardableResult
    static func addPaper(_ id: String = "paper-\(UUID().uuidString.prefix(8))", figures: Bool = false) throws -> String {
        let extracted = Core.paperDir(id).appendingPathComponent("extracted")
        ensureDirectory(extracted)
        func section(_ title: String, _ kind: String, _ blocks: [String]) -> [String: Any] {
            ["title": title, "level": 2, "page": 1, "kind": kind, "blocks": blocks]
        }
        let introduction = figures
            ? ["We study snow. Fig. 1 shows a point cloud.", "It works well."]
            : ["We study snow.", "It works well."]
        let text: [String: Any] = [
            "paper_id": id,
            "source_pdf": "\(id).pdf",
            "sections": [
                section("", "frontmatter", ["Jane Doe, jane@example.com"]),
                section("1 Introduction", "body", introduction),
                section("2 Method", "body", ["We filter it."]),
                section("References", "references", ["[1] A citation."]),
            ],
            "references": figures ? [["matched_text": "Fig. 1", "kind": "fig", "number": "1"]] : [],
        ]
        try JSONSerialization.data(withJSONObject: text).write(to: extracted.appendingPathComponent("text.json"))
        let figureEntries: [[String: Any]] = figures
            ? [["id": "Figure 1", "page": 1, "bbox": [0, 0, 1, 1], "caption": "Fig. 1: A point cloud.", "crop_path": "", "type": "figure"]]
            : []
        try JSONSerialization.data(withJSONObject: ["figures": figureEntries, "tables": [], "equations": []])
            .write(to: extracted.appendingPathComponent("figures.json"))
        return id
    }
}
