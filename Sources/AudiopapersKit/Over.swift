import Foundation

/// "Over" at the end of a question or a note, as on a radio, says it's finished, so pauses to think
/// along the way don't end it (see SpeechListening's untilOver).
public enum Over {
    private static let trailing = try! NSRegularExpression(pattern: #"[\s,;:-]*\bover(?:\s+and\s+out)?[\s,.;:!?-]*$"#, options: [.caseInsensitive])

    // Words "over" often finishes on its own, as in "can you go over", which aren't the end of
    // anything. Said straight after one of these, it needs saying again.
    private static let phrasal: Set<String> = [
        "go", "goes", "going", "went", "gone", "look", "looks", "looking", "looked", "read", "reading", "think",
        "thinking", "start", "starting", "started", "all", "take", "takes", "taking", "took", "hand", "turn",
        "pass", "run", "get", "fall", "falls", "come", "comes", "came", "carry", "carried", "left", "spill",
    ]

    private static func match(_ text: String) -> NSRange? {
        trailing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
    }

    /// Whether the last thing in `text` is "over" said to finish it.
    public static func endsWith(_ text: String) -> Bool {
        guard let range = match(text), let start = Range(range, in: text)?.lowerBound else { return false }
        let before = text[..<start].trimmingCharacters(in: .whitespaces).split(separator: " ").last.map(String.init) ?? ""
        return !phrasal.contains(before.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?")))
    }

    /// `text` without the "over" that finished it.
    public static func strip(_ text: String) -> String {
        guard endsWith(text), let range = match(text), let start = Range(range, in: text)?.lowerBound else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        return String(text[..<start]).trimmingCharacters(in: .whitespaces)
    }

    /// Two stretches of speech as one.
    public static func join(_ first: String, _ second: String) -> String {
        [first, second].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
