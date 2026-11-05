import AudiopapersKit
import SwiftUI

/// A paper's summary drawn as formatted text: audiopapers_core works out the blocks and inline marks
/// (client_text.summary_blocks), including the figures section's images, shown as the figure's crop.
struct SummaryView: View {
    let services: AppServices
    let paperId: String
    @State private var model: SummaryModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = SummaryModel(paperId: paperId, engine: services.engine) }
        }
    }

    @ViewBuilder
    private func content(_ model: SummaryModel) -> some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .generating:
            VStack(spacing: 16) {
                ProgressView()
                Text("Writing the summary").font(.headline)
                Text("Gemini reads the whole paper, so this can take a minute. It's only written once: after that, your questions, notes and figure descriptions are added each time you open it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
        case .notGenerated:
            VStack(spacing: 16) {
                Text("No summary generated yet for this paper.").multilineTextAlignment(.center)
                Button("Generate") { model.generate() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 40)
        case .error(let message):
            Text("Something went wrong: \(message)").multilineTextAlignment(.center).padding(.horizontal, 40)
        case .ready(let blocks, _):
            // Opening the summary brings it up to date, so there's nothing to regenerate.
            VStack(alignment: .leading, spacing: 8) {
                if model.canSpeak { SpeakSummary(engine: services.engine, model: model) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            BlockView(paperId: paperId, block: block)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 24)
        }
    }
}

/// Plays the summary aloud, in the voice picked for it in Settings.
private struct SpeakSummary: View {
    let engine: ReadingEngine
    let model: SummaryModel

    var body: some View {
        Button {
            model.toggleSpeech()
        } label: {
            HStack(spacing: 8) {
                if engine.summarySpeech == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                }
                Text(engine.summarySpeech == .preparing ? "Preparing..." : engine.summarySpeech == .ready && engine.isPlaying ? "Pause" : "Play")
            }
        }
        .buttonStyle(.bordered)
        .padding(.top, 8)
        if let message = engine.message {
            HStack {
                Text(message).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                Button("OK") { engine.dismissMessage() }
            }
        }
    }
}

private struct BlockView: View {
    let paperId: String
    let block: SummaryBlock

    private func styled(_ base: Font) -> AttributedString {
        var text = AttributedString()
        for span in block.spans ?? [] {
            var part = AttributedString(span.text)
            switch span.style {
            case "bold": part.font = base.bold()
            case "italic": part.font = base.italic()
            case "code": part.font = base.monospaced()
            case "underline":
                part.font = base
                part.underlineStyle = .single
            default: part.font = base
            }
            text.append(part)
        }
        return text
    }

    var body: some View {
        switch block.type {
        case "heading":
            let level = block.level ?? 3
            Text(styled(level == 1 ? .title2 : level == 2 ? .title3 : .headline))
                .padding(.top, level <= 2 ? 12 : 4)
        case "item":
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(block.marker ?? "•")
                Text(styled(.body))
            }
            .padding(.leading, CGFloat((block.depth ?? 0) * 16))
        case "image":
            FigureImage(paperId: paperId, figureId: block.figureId ?? "", label: block.label ?? "", maxHeight: 420)
        case "rule":
            Divider()
        default:
            Text(styled(.body))
        }
    }
}
