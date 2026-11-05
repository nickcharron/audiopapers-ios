import AudiopapersKit
import Observation
import PDFKit
import SwiftUI

private enum PdfState {
    case loading
    case error(String)
    /// `page` is where to open: the paragraph being read (`selection`, to highlight) or, failing
    /// that, the page its section starts on.
    case ready(document: PDFDocument, page: Int, selection: PDFSelection?)
}

/// Opens the paper's PDF and works out where the paragraph being read is. The paragraph's narrated
/// text has had citations removed and "Fig." spelled out, so a few short runs of its words are tried
/// in turn (client_text.pdf_search_queries), from its section's page onwards, until one is found.
@MainActor
@Observable
private final class PdfModel {
    var state = PdfState.loading
    let pdf: URL

    init(paperId: String, engine: ReadingEngine) {
        pdf = Core.paperDir(paperId).appendingPathComponent("source.pdf")
        let paragraph = engine.currentParagraph()
        Task { await load(sectionPage: paragraph.page, text: paragraph.text) }
    }

    private func load(sectionPage: Int?, text: String?) async {
        guard let document = PDFDocument(url: pdf) else {
            state = .error("Couldn't open the PDF.")
            return
        }
        guard document.pageCount > 0 else {
            state = .error("The PDF has no pages.")
            return
        }
        let start = max(0, min((sectionPage ?? 1) - 1, document.pageCount - 1))
        state = .ready(document: document, page: start, selection: nil)
        guard let text, let queries = try? await Core.pdfSearchQueries(text) else { return }
        for query in queries {
            let matches = document.findString(query, withOptions: [.caseInsensitive])
            func page(of match: PDFSelection) -> Int { match.pages.first.map { document.index(for: $0) } ?? 0 }
            // From the section's page onwards, then wrapping round.
            if let match = matches.first(where: { page(of: $0) >= start }) ?? matches.first {
                state = .ready(document: document, page: page(of: match), selection: match)
                return
            }
        }
    }
}

/// The paper's own PDF, opened where narration is: scrolled to the paragraph being read and
/// highlighted when it can be found, otherwise at the page its section starts on. "Open in another
/// app" hands the PDF to a full viewer.
struct PdfScreen: View {
    let services: AppServices
    let paperId: String
    @State private var model: PdfModel?

    var body: some View {
        Group {
            switch model?.state {
            case .ready(let document, let page, let selection)?:
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(selection != nil ? "Page \(page + 1): the paragraph being read is highlighted." : "Page \(page + 1), where this section starts.")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let pdf = model?.pdf {
                            ShareLink("Open in another app", item: pdf).font(.subheadline)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    PdfKitView(document: document, page: page, selection: selection)
                }
            case .error(let message)?:
                Text(message).multilineTextAlignment(.center).padding(.horizontal, 40)
            default:
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = PdfModel(paperId: paperId, engine: services.engine) }
        }
    }
}

private struct PdfKitView: UIViewRepresentable {
    let document: PDFDocument
    let page: Int
    let selection: PDFSelection?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if let selection {
            selection.color = UIColor.tintColor.withAlphaComponent(0.3)
            view.highlightedSelections = [selection]
            view.go(to: selection)
        } else if let target = document.page(at: page) {
            view.go(to: target)
        }
    }
}
