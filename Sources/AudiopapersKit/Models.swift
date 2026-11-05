import Foundation

// Mirrors the JSON audiopapers_core's bridge returns (audiopapers_core/bridge.py and service.py
// in the main audiopapers repo): plain structs, one property per JSON field, decoded with
// convertFromSnakeCase so a change on the Python side is a one-line diff here too.

public struct PaperSummary: Codable, Equatable, Identifiable, Sendable {
    public var paperId: String
    public var sections: Int
    public var sectionIndex: Int
    public var segmentIndex: Int
    public var done: Bool
    public var id: String { paperId }
}

public struct PaperDetail: Codable, Equatable, Sendable {
    public var paperId: String
    public var sourcePdf: String
    public var sections: Int
    public var session: SessionView
}

public struct PendingPrompt: Codable, Equatable, Sendable {
    public var label: String
    public var resolvedId: String?
    /// Slug of the figure/table/equation being asked about (see FigureCropper), so the prompt can
    /// show it; nil when the mention didn't resolve to an extracted item.
    public var figureId: String?
}

public struct PlayInfo: Codable, Equatable, Sendable {
    public var type: String // "segment" | "description"
    /// Stable id for this audio: the key its rendered speech is cached under.
    public var audioId: String
    /// The words to speak: the segment's text, or the generated description.
    public var text: String?
    public var label: String? // only for type == "description"
    public var figureId: String? // only for type == "description"
}

public struct SessionView: Codable, Equatable, Sendable {
    public var paperId: String
    public var sectionIndex: Int
    public var segmentIndex: Int
    public var totalSections: Int
    public var sectionTitle: String?
    /// The PDF page the current section starts on, if known.
    public var sectionPage: Int?
    public var rate: Float
    public var done: Bool
    public var pendingPrompt: PendingPrompt?
    public var play: PlayInfo?
}

/// One speakable segment, in reading order (service.narration).
public struct NarrationSegment: Codable, Equatable, Sendable {
    public var sectionIndex: Int
    public var segmentIndex: Int
    public var audioId: String
    public var text: String
    public var sectionTitle: String?
}

public struct AnswerResult: Codable, Equatable, Sendable {
    public var question: String
    public var answer: String
    public var answerId: String
}

public struct Note: Codable, Equatable, Sendable {
    public var kind: String // "note" | "todo"
    public var text: String
    public var location: String
    public var timestamp: String
}

public struct RenamedPaper: Codable, Equatable, Sendable {
    public var paperId: String
}

public struct IngestResult: Codable, Equatable, Sendable {
    public var paperId: String
    public var sections: Int
    public var figures: Int
    public var tables: Int
    public var equations: Int
}

/// A figure/table/equation's entry in figures.json: where it is in the PDF.
public struct FigureEntry: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var page: Int?
    /// [ymin, xmin, ymax, xmax] on the page, each scaled 0-1000.
    public var box2d: [Int]?
    public var caption: String?
}

/// A JSON value that may be a string, number or boolean, read as its text.
public struct JSONScalar: Codable, Equatable, Sendable {
    public var content: String

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            content = flag ? "true" : "false"
        } else if let number = try? container.decode(Double.self) {
            content = String(number)
        } else {
            content = try container.decode(String.self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(content)
    }
}

/// What something said to Albert asks for (voice.py). Which fields are set depends on `action`.
public struct VoiceCommand: Codable, Equatable, Sendable {
    public var action: String
    /// A question, a note's words, a new name for a paper, or what the help command says.
    public var text: String?
    public var sectionIndex: Int?
    public var sectionTitle: String?
    public var figureId: String?
    public var figureLabel: String?
    public var paperId: String?
    public var speed: Float?
    public var setting: String?
    /// A setting's new value (true or false), or the name of a VoiceEngine.
    public var value: JSONScalar?
    public var kind: String? // "note" | "todo"
    public var query: String? // a section asked for that wasn't found
    public var via: String? // "phrase" | "gemini"
}

/// What to say to describe one figure, table or equation asked for by name.
public struct FigureDescription: Codable, Equatable, Sendable {
    public var figureId: String
    public var label: String
    public var text: String
}

/// A run of text in a summary, with its inline mark if it has one.
public struct SummarySpan: Codable, Equatable, Sendable {
    public var text: String
    public var style: String? // "bold" | "italic" | "code" | "underline"
}

/// One block of a summary to draw (client_text.summary_blocks).
public struct SummaryBlock: Codable, Equatable, Sendable {
    public var type: String // "heading" | "paragraph" | "item" | "image" | "rule"
    public var level: Int?
    public var text: String?
    public var marker: String?
    public var depth: Int?
    public var label: String?
    public var figureId: String?
    public var spans: [SummarySpan]?
}
