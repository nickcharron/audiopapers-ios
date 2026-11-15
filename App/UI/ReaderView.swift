import AudiopapersKit
import SwiftUI
import UIKit

// A fixed step with a floor, as on the other platforms.
private let rateStep: Float = 0.25
private let minRate: Float = 0.25
private let spokenPollNanoseconds: UInt64 = 300_000_000
private let manualScrollHold: TimeInterval = 5
private let followSlack: CGFloat = 24

/// What's showing over the reader. Only one can be at a time.
private enum ReaderDialog: Identifiable, Equatable {
    case message(String)
    case prompt(PendingPrompt)
    case answered(question: String, answer: String, answerId: String, done: Bool)
    case telling(title: String, text: String, figureId: String?, done: Bool)
    case failed(String)
    case note

    var id: String {
        switch self {
        case .message(let text): return "message:\(text)"
        case .prompt(let prompt): return "prompt:\(prompt.label)"
        case .answered(_, _, let answerId, _): return "answered:\(answerId)"
        case .telling(let title, let text, _, _): return "telling:\(title):\(text.hashValue)"
        case .failed(let text): return "failed:\(text)"
        case .note: return "note"
        }
    }
}

/// Playback itself lives in ReadingEngine (so it survives the screen locking); this screen only
/// shows its state and sends it commands.
struct ReaderView: View {
    let services: AppServices
    let paperId: String
    @Binding var path: [Route]

    @State private var notePromptOpen = false
    @State private var noteText = ""
    @State private var noteListening = false
    @Environment(\.scenePhase) private var scenePhase

    private var engine: ReadingEngine { services.engine }
    private var voice: VoiceController { services.voice }

    /// Asked about figures in Settings: with prompts off, ReadingEngine answers "no" itself.
    private var dialog: ReaderDialog? {
        if let message = engine.message { return .message(message) }
        if let prompt = engine.uiState.session?.pendingPrompt, Settings.askAboutFigures { return .prompt(prompt) }
        switch engine.interjectionState {
        case .answered(let question, let answer, _, let answerId, let done):
            return .answered(question: question, answer: answer, answerId: answerId, done: done)
        // Something longer Albert's reading out, on screen too. Short replies need no dialog.
        case .telling(let title, let text, _, let figureId, _, let done) where title != ReadingEngine.shortReply:
            return .telling(title: title, text: text, figureId: figureId, done: done)
        case .failed(let problem):
            return .failed(problem)
        default:
            break
        }
        return notePromptOpen ? .note : nil
    }

    var body: some View {
        Group {
            switch engine.uiState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                VStack(spacing: 16) {
                    Text("Something went wrong: \(message)")
                    Button("Retry") { engine.retryLoad() }.buttonStyle(.borderedProminent)
                }
                .padding(24)
            case .ready(let session):
                ReaderContent(services: services, paperId: paperId, session: session, path: $path) {
                    engine.pauseForAside()
                    noteText = ""
                    notePromptOpen = true
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            engine.open(paperId)
            // Back from the summary: resume narration if the Summary button paused it. Not while
            // the note sheet is open.
            if !notePromptOpen { engine.endAside() }
            askForTheMicIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !notePromptOpen { engine.endAside() }
        }
        .sheet(item: Binding(get: { dialog }, set: { if $0 == nil { dismissDialog() } })) { dialog in
            dialogView(dialog)
        }
    }

    /// "Hey Albert" is on until turned off, so the mic is first asked for here (or again, if the
    /// permission's since been taken away). Saying no turns it off rather than asking every time.
    private func askForTheMicIfNeeded() {
        guard Settings.heyAlbert, !Permissions.micAllowed() else { return }
        Task {
            let allowed = await Permissions.requestMicAndSpeech()
            // For the notification when Albert stops listening by itself.
            await LocalNotifier.requestPermission()
            if allowed {
                voice.syncListening()
            } else {
                Settings.heyAlbert = false
            }
        }
    }

    private func dismissDialog() {
        switch dialog {
        case .message?: engine.dismissMessage()
        case .answered?, .telling?, .failed?: engine.dismissInterjection()
        case .note?: closeNote()
        case .prompt?, nil: break
        }
    }

    private func closeNote() {
        if noteListening { services.input.cancel() }
        noteListening = false
        notePromptOpen = false
        engine.endAside()
    }

    /// Speaking a note instead of typing it: what's heard is added to the note's text, to check or
    /// edit before saving.
    private func toggleNoteListening() {
        if noteListening {
            services.input.stop() // the recognizer then reports what it heard
            return
        }
        noteListening = true
        services.input.listen(
            mode: .dictation,
            terms: [],
            fromWake: false,
            onPartial: { _ in },
            onText: { heard in
                noteListening = false
                if let heard, !heard.isEmpty {
                    noteText = [noteText.trimmingCharacters(in: .whitespaces), heard].filter { !$0.isEmpty }.joined(separator: " ")
                }
            },
            onFailure: { _ in noteListening = false },
            onSayAgain: { noteListening = false }
        )
    }

    @ViewBuilder
    private func dialogView(_ dialog: ReaderDialog) -> some View {
        switch dialog {
        case .message(let text):
            DialogCard(title: "Something went wrong") {
                Text(text)
            } buttons: {
                Button("OK") { engine.dismissMessage() }.buttonStyle(.borderedProminent)
            }
        case .prompt(let prompt):
            promptSheet(prompt)
        case .answered(let question, let answer, let answerId, let done):
            DialogCard(title: "Q: \(question)") {
                ScrollView {
                    VStack(spacing: 12) {
                        Text(answer).frame(maxWidth: .infinity, alignment: .leading)
                        if done { waitingHint(followUp: true) }
                    }
                }
            } buttons: {
                Button("Follow up") { withMic { voice.askFollowUp(answerId) } }.buttonStyle(.bordered)
                Button("Done") { engine.dismissInterjection() }.buttonStyle(.borderedProminent)
            }
        case .telling(let title, let text, let figureId, let done):
            DialogCard(title: title) {
                ScrollView {
                    VStack(spacing: 12) {
                        if let figureId { FigureImage(paperId: paperId, figureId: figureId, label: title, maxHeight: 280) }
                        Text(text).frame(maxWidth: .infinity, alignment: .leading)
                        if done { waitingHint(followUp: false) }
                    }
                }
            } buttons: {
                Button("Done") { engine.dismissInterjection() }.buttonStyle(.borderedProminent)
            }
        case .failed(let problem):
            DialogCard(title: "Couldn't get an answer") {
                Text(problem)
            } buttons: {
                Button("OK") { engine.dismissInterjection() }.buttonStyle(.borderedProminent)
            }
        case .note:
            noteSheet
        }
    }

    /// Under an answer, recap or summary that's been read out: how to carry on, since narration
    /// waits to be told.
    private func waitingHint(followUp: Bool) -> some View {
        let text: String
        switch (voice.handsFree, followUp) {
        case (true, true):
            text = "Done answering, waiting on your next instruction. Say \"Hey Albert, continue\" to keep reading the paper, or \"Hey Albert\" and a follow-up question."
        case (true, false):
            text = "Waiting on your next instruction. Say \"Hey Albert, continue\" to keep reading the paper."
        case (false, true):
            text = "Done answering. Tap Done to keep reading the paper, or Follow up to ask more."
        case (false, false):
            text = "Tap Done to keep reading the paper."
        }
        return Text(text).font(.footnote).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The figure/table/equation itself sits between the question and the Yes/No buttons, capped in
    /// height so all three fit on screen together -- the point is to glance at it and decide.
    private func promptSheet(_ prompt: PendingPrompt) -> some View {
        DialogCard(title: engine.isDescribing ? "Thinking..." : "Describe \(prompt.label)?") {
            VStack(spacing: 12) {
                if let figureId = prompt.figureId {
                    FigureImage(paperId: paperId, figureId: figureId, label: prompt.label, maxHeight: 360)
                }
                if engine.listeningForAnswer && !engine.isDescribing {
                    Text("Listening... say yes or no, or tap below")
                }
                if engine.isDescribing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Generating the description...")
                    }
                }
            }
        } buttons: {
            if !engine.isDescribing {
                Button("No") { engine.describeNo() }.buttonStyle(.bordered)
                Button("Yes") { engine.describeYes() }.buttonStyle(.borderedProminent)
            }
        }
        .interactiveDismissDisabled() // must answer yes or no
    }

    private var noteSheet: some View {
        DialogCard(title: "Add a note") {
            VStack(spacing: 12) {
                MascotView(state: .takingNotes).frame(width: 72, height: 72)
                HStack(alignment: .top) {
                    TextField(
                        noteListening ? "Listening..." : "Type or tap the mic. Start with \"todo\" for a TODO",
                        text: $noteText,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    if services.input.isAvailable {
                        Button {
                            withMic { toggleNoteListening() }
                        } label: {
                            Image(systemName: "mic.fill").foregroundStyle(noteListening ? Color.accentColor : Color.secondary)
                        }
                        .accessibilityLabel(noteListening ? "Stop listening" : "Speak your note")
                    }
                }
            }
        } buttons: {
            Button("Cancel") { closeNote() }.buttonStyle(.bordered)
            Button("Save") {
                if !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { engine.addNote(noteText) }
                closeNote()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A sheet with a title, something in the middle and buttons along the bottom, the app's dialogs.
private struct DialogCard<Content: View, Buttons: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.bold())
            content()
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Spacer()
                buttons()
            }
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }
}

/// Only the section text scrolls, in a column filling whatever space the fixed controls below don't
/// take, so a long section can't push the controls off-screen.
private struct ReaderContent: View {
    let services: AppServices
    let paperId: String
    let session: SessionView
    @Binding var path: [Route]
    let openNote: () -> Void

    @State private var spoken: Range<Int>?
    @State private var position = ScrollPosition(edge: .top)
    @State private var textFrame = CGRect.zero
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var scrolledY: CGFloat = 0
    @State private var lastDragAt = Date.distantPast

    private var engine: ReadingEngine { services.engine }
    private var voice: VoiceController { services.voice }
    private var play: PlayInfo? { session.play }

    private var mascotState: MascotState {
        switch voice.state {
        case .hearing, .confirming: return .listening
        case .understanding: return .thinking
        default: break
        }
        if engine.interjectionState == .thinking { return .thinking }
        return engine.isPlaying ? .reading : .sleeping
    }

    private var shown: String {
        if play?.type == "description" { return "Describing \(play?.label ?? "")..." }
        return play?.text ?? ""
    }

    private var attributedText: AttributedString {
        var text = AttributedString(shown)
        if Settings.highlightSpoken, let spoken, spoken.upperBound <= text.characters.count, !spoken.isEmpty {
            let start = text.characters.index(text.startIndex, offsetBy: spoken.lowerBound)
            let end = text.characters.index(text.startIndex, offsetBy: spoken.upperBound)
            text[start..<end].backgroundColor = Color.accentColor.opacity(0.25)
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    MascotView(state: mascotState).frame(width: 120, height: 120)
                    Spacer().frame(height: 12)
                    if session.done {
                        Text("Done reading.").font(.title2)
                    } else {
                        Text("Section \(session.sectionIndex + 1)/\(session.totalSections)").font(.caption)
                        Text(session.sectionTitle ?? "").font(.title2).multilineTextAlignment(.center)
                    }
                    Spacer().frame(height: 16)
                    if play?.type == "description", let figureId = play?.figureId {
                        // The actual figure/table/equation being described.
                        FigureImage(paperId: paperId, figureId: figureId, label: play?.label ?? "", maxHeight: 280)
                        Spacer().frame(height: 12)
                    }
                    Text(attributedText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("readerContent")) } action: { textFrame = $0 }
                    listeningLine
                }
                .coordinateSpace(name: "readerContent")
            }
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { lastDragAt = Date() }
            }
            .onScrollGeometryChange(for: CGSize.self) { CGSize(width: $0.containerSize.height, height: $0.contentSize.height) } action: { _, sizes in
                viewportHeight = sizes.width
                contentHeight = sizes.height
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in scrolledY = y }

            Spacer().frame(height: 24)
            controls
        }
        .padding(24)
        .task(id: "\(play?.audioId ?? "")/\(engine.isPlaying)") { await followNarration() }
        .onChange(of: play?.audioId) { _, _ in
            // Back to the top when a new paragraph starts.
            spoken = nil
            withAnimation { position.scrollTo(y: 0) }
        }
    }

    @ViewBuilder
    private var listeningLine: some View {
        if engine.interjectionState == .listening {
            Spacer().frame(height: 16)
            if case .hearing(let words, _) = voice.state, !words.isEmpty {
                Text("\"\(words)\"")
            } else {
                Text("Listening... go ahead, or tap Stop when done")
            }
            if case .hearing(_, let hint?) = voice.state {
                Text(hint).font(.footnote).foregroundStyle(Color.accentColor)
            }
        } else if engine.interjectionState == .thinking {
            Spacer().frame(height: 16)
            Text("Thinking...")
        }
    }

    /// Keeps the sentence being read highlighted and on screen in a long paragraph, updated while
    /// playing. Speech doesn't run at an even pace, so it's a sentence rather than a word: close
    /// enough to follow along, without jumping around. A drag by the listener takes priority.
    private func followNarration() async {
        guard Settings.highlightSpoken || Settings.followSpoken, let play, play.type == "segment", let text = play.text, !text.isEmpty else {
            spoken = nil
            return
        }
        let count = text.count
        repeat {
            let offset = Int(engine.spokenFraction(play.audioId) * Float(count))
            let sentence = Sentences.around(text, offset: offset)
            spoken = sentence
            if Settings.followSpoken { scrollTo(sentence, in: text) }
            try? await Task.sleep(nanoseconds: spokenPollNanoseconds)
        } while engine.isPlaying && !Task.isCancelled
    }

    private func scrollTo(_ sentence: Range<Int>, in text: String) {
        if Date().timeIntervalSince(lastDragAt) < manualScrollHold || textFrame.width <= 0 { return }
        let top = textFrame.minY + lineTop(ofCharacter: sentence.lowerBound, in: text, width: textFrame.width)
        // A third of the way down the view.
        let target = max(0, min(top - viewportHeight / 3, contentHeight - viewportHeight))
        if abs(target - scrolledY) > followSlack {
            withAnimation { position.scrollTo(y: target) }
        }
    }

    /// Where a character's line starts, laid out as the body text above is.
    private func lineTop(ofCharacter offset: Int, in text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let index = text.index(text.startIndex, offsetBy: min(offset, text.count))
        let utf16 = index.utf16Offset(in: text)
        if utf16 >= layout.numberOfGlyphs && utf16 > 0 { return 0 }
        let glyph = layout.glyphIndexForCharacter(at: utf16)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                // Nothing left to play once finished; Restart or Previous goes back in.
                Button(engine.isPlaying ? "Pause" : "Play") { engine.togglePlayPause() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.done)
                AlbertButton(voiceState: voice.state) {
                    withMic {
                        voice.syncListening()
                        voice.pushToTalk()
                    }
                }
            }
            AlbertStatus(voiceState: voice.state, heard: voice.heard)
            NavigationRow(unit: "Paragraph", nextEnabled: !session.done, onRestart: engine.restartParagraph, onPrevious: engine.previousParagraph, onNext: engine.nextParagraph)
            NavigationRow(unit: "Section", nextEnabled: !session.done, onRestart: engine.restartSection, onPrevious: engine.previousSection, onNext: engine.nextSection)
            HStack(spacing: 16) {
                Button("−") { engine.setRate(max(engine.rate - rateStep, minRate)) }.buttonStyle(.borderedProminent)
                Text("\(engine.rate, specifier: "%g")x")
                Button("+") { engine.setRate(engine.rate + rateStep) }.buttonStyle(.borderedProminent)
            }
            // Four across, sharing the width equally, so they fit a phone screen.
            HStack(spacing: 8) {
                wideButton(engine.interjectionState == .listening ? "Stop" : "Ask") { askOrStop() }
                    .disabled(!(engine.interjectionState == .idle || engine.interjectionState == .listening))
                wideButton("Note") { openNote() }
                wideButton("Summary") {
                    engine.pauseForAside()
                    path.append(.summary(paperId))
                }
                wideButton("PDF") {
                    engine.pauseForAside()
                    path.append(.pdf(paperId))
                }
            }
        }
    }

    private func wideButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func askOrStop() {
        switch engine.interjectionState {
        case .idle:
            withMic {
                if services.input.isAvailable {
                    voice.askQuestion() // pauses narration, remembering where
                } else {
                    engine.listeningFailed("Speech recognition isn't available on this phone.")
                }
            }
        case .listening:
            voice.stopHearing() // the recognizer then reports what it heard
        default:
            break // the Ask button is disabled in those states
        }
    }
}

/// "Paragraph" or "Section", then Restart / Previous / Next buttons for it.
private struct NavigationRow: View {
    let unit: String
    let nextEnabled: Bool
    let onRestart: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(unit).font(.caption.bold())
            HStack(spacing: 12) {
                Button("Restart", action: onRestart).accessibilityLabel("Restart \(unit.lowercased())")
                Button("Previous", action: onPrevious).accessibilityLabel("Previous \(unit.lowercased())")
                Button("Next", action: onNext).disabled(!nextEnabled).accessibilityLabel("Next \(unit.lowercased())")
            }
            .buttonStyle(.bordered)
        }
    }
}
