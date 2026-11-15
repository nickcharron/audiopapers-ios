import AudiopapersKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's home screen: a welcoming mascot clip up top, then "Start new paper" (pick a local PDF,
/// run ingest) and "Resume paper" (every ingested paper, scrollable) below.
struct HomeView: View {
    let services: AppServices
    @Binding var path: [Route]

    @State private var picking = false
    @State private var downloadAudioOnAdd = false
    // A paper whose audio download is waiting for confirmation, with its paragraph count.
    @State private var downloadTarget: DownloadTarget?
    // A paper tapped before its Kokoro audio is ready.
    @State private var notReadyTarget: String?
    // Which paper (if any) the menu's Remove/Clear/Rename confirmation is currently asking about.
    @State private var removeTarget: String?
    @State private var clearTarget: String?
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var pickFailure: String?

    @Environment(\.scenePhase) private var scenePhase

    private struct DownloadTarget: Equatable {
        var paperId: String
        var paragraphs: Int?
    }

    private var model: HomeModel { services.home }
    private var jobs: BackgroundJobs { services.jobs }
    private var voice: VoiceController { services.voice }

    private var ingesting: (fileName: String, pagesDone: Int, totalPages: Int)? {
        if case .ingesting(let fileName, let pagesDone, let totalPages) = jobs.ingestState { return (fileName, pagesDone, totalPages) }
        return nil
    }

    private var mascotState: MascotState {
        if ingesting != nil { return .ingesting }
        switch voice.state {
        case .hearing: return .listening
        case .understanding: return .thinking
        default: return .home
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if case .hearing(let words, _) = voice.state {
                Text(words.isEmpty ? "Listening..." : words).font(.caption)
            }
            MascotView(state: mascotState)
                .frame(width: 200, height: 200)
                .frame(maxWidth: .infinity)
            content.padding(.horizontal, 24)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
        .onChange(of: jobs.finishedCount) { _, _ in model.refresh() }
        // "Hey Albert, add a paper" lands here.
        .onChange(of: services.navigator.addPaperRequested, initial: true) { _, requested in
            guard requested else { return }
            services.navigator.addPaperHandled()
            startAddingPaper()
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): add(url)
            case .failure(let error): pickFailure = error.localizedDescription
            }
        }
        .modifier(HomeAlerts(view: self))
    }

    private var header: some View {
        ZStack {
            // Baked-in pixels rather than text, with a light and a dark version in the asset catalog.
            Image("Wordmark").resizable().scaledToFit().frame(height: 40).accessibilityLabel("Audiopapers")
            HStack {
                Button {
                    // No paper's open here, so nothing's listening for "Hey Albert": the button is the way in.
                    withMic { voice.pushToTalk() }
                } label: {
                    Image(systemName: "mic.fill").foregroundStyle(voice.state.isHearing ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel("Talk to Albert")
                Spacer()
                Button { path.append(.settings) } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let ingesting {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ingesting \(ingesting.fileName)...").font(.subheadline)
                if ingesting.totalPages > 0 {
                    // Gemini reads the paper a few pages at a time; this moves per chunk.
                    ProgressView(value: Double(ingesting.pagesDone), total: Double(ingesting.totalPages))
                    Text("\(ingesting.pagesDone) of \(ingesting.totalPages) pages read").font(.caption)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !model.hasKey { setupCard }
                Text("Start new paper").font(.title2.bold())
                Button { startAddingPaper() } label: {
                    Text("Choose a PDF").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if model.prepareFirst {
                    Text("With the Kokoro voice, a new paper's audio is prepared after it's added, before you can listen. That takes about as long as the paper; best while charging.")
                        .font(.caption)
                } else {
                    Toggle(isOn: $downloadAudioOnAdd) {
                        VStack(alignment: .leading) {
                            Text("Also download audio for offline listening")
                            if model.voice.isGemini {
                                Text("Gemini voice: about one request per paragraph from your quota.").font(.caption)
                            }
                        }
                    }
                }
                Text("Resume paper").font(.title2.bold()).padding(.top, 8)
                papers
            }
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set up Gemini to add papers").font(.headline)
            Text("Free with your own Google key, no credit card. About two minutes.")
            Button("Set up") { path.append(.setup) }.buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var papers: some View {
        switch model.papers {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            VStack {
                Text("Couldn't load your papers: \(message)")
                Button("Retry") { model.refresh() }.buttonStyle(.borderedProminent)
                Spacer()
            }
        case .loaded(let papers) where papers.isEmpty:
            Text("No papers yet -- start one above.")
            Spacer()
        case .loaded(let papers):
            List(papers) { paper in row(paper).listRowInsets(EdgeInsets()) }
                .listStyle(.plain)
        }
    }

    private func row(_ paper: PaperSummary) -> some View {
        HStack(spacing: 12) {
            PaperStatusRing(sectionIndex: paper.sectionIndex, segmentIndex: paper.segmentIndex, totalSections: paper.sections, done: paper.done)
            VStack(alignment: .leading, spacing: 2) {
                Text(paper.paperId)
                Text("\(paper.sections) sections").font(.subheadline).foregroundStyle(.secondary)
                audioLine(paper.paperId)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { open(paper.paperId) }
            menu(paper.paperId)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func audioLine(_ paperId: String) -> some View {
        let prepareFirst = model.prepareFirst
        switch model.audioStatus(paperId) {
        case .downloading(let done, let total)?:
            let verb = prepareFirst ? "Preparing" : "Downloading"
            Text(total > 0 ? "\(verb) audio: \(done) of \(total) paragraphs" : "\(verb) audio...").font(.caption)
        case .ready?:
            Text(prepareFirst ? "Audio ready" : "Offline audio ready").font(.caption)
        case .failed(let message)?:
            Text("Audio \(prepareFirst ? "preparation" : "download"): \(message)").font(.caption).foregroundStyle(.red)
        case nil:
            if prepareFirst { Text("Audio not prepared yet").font(.caption) }
        }
    }

    private func menu(_ paperId: String) -> some View {
        Menu {
            Button("Rename") {
                renameText = paperId
                renameTarget = paperId
            }
            audioMenuItem(paperId)
            Button("Mark read") { model.markPaperRead(paperId) }
            Button("Clear") { clearTarget = paperId }
            Button("Remove", role: .destructive) { removeTarget = paperId }
        } label: {
            Image(systemName: "gearshape").accessibilityLabel("Options for \(paperId)")
        }
    }

    @ViewBuilder
    private func audioMenuItem(_ paperId: String) -> some View {
        let prepareFirst = model.prepareFirst
        switch model.audioStatus(paperId) {
        case .downloading?:
            Button(prepareFirst ? "Stop preparing audio" : "Stop audio download") { jobs.cancelAudio(paperId) }
        case .ready?:
            Button(prepareFirst ? "Audio ready" : "Offline audio ready") {}.disabled(true)
        case let status:
            let failed: Bool = { if case .failed? = status { return true } else { return false } }()
            Button(prepareFirst ? (failed ? "Finish preparing audio" : "Prepare audio") : (failed ? "Finish downloading audio" : "Download audio for offline")) {
                if prepareFirst {
                    notReadyTarget = paperId
                } else {
                    Task {
                        let paragraphs = await model.paragraphCount(paperId)
                        downloadTarget = DownloadTarget(paperId: paperId, paragraphs: paragraphs)
                    }
                }
            }
        }
    }

    private func open(_ paperId: String) {
        if model.prepareFirst && model.audioStatus(paperId) != .ready {
            notReadyTarget = paperId
        } else {
            path.append(.reader(paperId))
        }
    }

    /// Asks before an app can notify, when starting a job that ends with a notification. The job
    /// goes ahead either way.
    private func withNotifications(_ action: @escaping @MainActor () -> Void) {
        Task {
            await LocalNotifier.requestPermission()
            action()
        }
    }

    private func startAddingPaper() {
        if model.hasKey {
            withNotifications { picking = true }
        } else {
            path.append(.setup)
        }
    }

    /// What the file picker returned may be somewhere only it can reach, so this copies it into the
    /// app's own storage under its real name: the paper id comes from the filename, so a generic
    /// name would make different papers collide.
    private func add(_ picked: URL) {
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        let fileName = picked.lastPathComponent
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ingest-\(UUID().uuidString)")
        let copy = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: picked, to: copy)
        } catch {
            pickFailure = "Couldn't read that PDF (\(error.localizedDescription))"
            return
        }
        // With the Kokoro voice the new paper stays here, preparing its audio, rather than opening
        // straight away.
        let prepareFirst = model.prepareFirst
        jobs.ingest(pdf: copy, fileName: fileName, downloadAudio: downloadAudioOnAdd || prepareFirst) { paperId in
            model.refresh()
            if !prepareFirst { path.append(.reader(paperId)) }
        }
    }

    /// All the home screen's dialogs.
    private struct HomeAlerts: ViewModifier {
        let view: HomeView

        private func binding<T>(_ value: T?, clear: @escaping () -> Void) -> Binding<Bool> {
            Binding(get: { value != nil }, set: { if !$0 { clear() } })
        }

        private var ingestFailure: String? {
            if case .failed(let message) = view.jobs.ingestState { return message }
            return nil
        }

        private var preparing: (done: Int, total: Int)? {
            guard let target = view.notReadyTarget, case .downloading(let done, let total)? = view.model.audioStatus(target) else { return nil }
            return (done, total)
        }

        private var notReadyMessage: String {
            let target = view.notReadyTarget ?? ""
            if let preparing {
                let progress = preparing.total > 0 ? ": \(preparing.done) of \(preparing.total) paragraphs done." : "."
                return "The Kokoro voice is still making \"\(target)\"\(progress) You can listen once it's finished, or pick another voice in Settings."
            }
            return "The Kokoro voice is made on the phone, which is too slow to keep up while you listen, so a paper's audio is prepared before you play it. For \"\(target)\" that takes about as long as listening to it. It runs in the background; best while charging."
        }

        private var downloadMessage: String {
            guard let target = view.downloadTarget else { return "" }
            if view.model.voice.isGemini {
                let count = target.paragraphs.map(String.init) ?? "one"
                return "Saves all of \"\(target.paperId)\" in the Gemini voice so it plays without a connection. That's \(count) paragraph\(target.paragraphs == 1 ? "" : "s"), one Gemini request each, from your quota. It runs in the background; if your daily limit runs out, it stops and you can finish it later."
            }
            if view.model.voice.isKokoro {
                return "Makes all of \"\(target.paperId)\" in the Kokoro voice ahead of time, so it plays with no wait between paragraphs. It runs in the background and can take a while, about as long as listening to the paper; it's best done while the phone is charging."
            }
            return "Saves all of \"\(target.paperId)\" in the phone voice ahead of time. The phone voice already works offline, so this only removes the short pause before each paragraph."
        }

        func body(content: Content) -> some View {
            content
                .alert("Couldn't ingest that PDF", isPresented: binding(ingestFailure) { view.jobs.dismissIngestError() }) {
                    Button("OK") { view.jobs.dismissIngestError() }
                } message: {
                    Text(ingestFailure ?? "")
                }
                .alert("Couldn't read that PDF", isPresented: binding(view.pickFailure) { view.pickFailure = nil }) {
                    Button("OK") {}
                } message: {
                    Text(view.pickFailure ?? "")
                }
                .alert("Something went wrong", isPresented: binding(view.model.actionFailure) { view.model.dismissActionFailure() }) {
                    Button("OK") {}
                } message: {
                    Text(view.model.actionFailure ?? "")
                }
                .alert(preparing != nil ? "Still preparing audio" : "Prepare audio first", isPresented: binding(view.notReadyTarget) { view.notReadyTarget = nil }) {
                    if preparing != nil {
                        Button("OK") {}
                    } else {
                        Button("Prepare") {
                            if let target = view.notReadyTarget {
                                view.withNotifications { view.jobs.downloadAudio(target) }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                } message: {
                    Text(notReadyMessage)
                }
                .alert("Download audio for offline?", isPresented: binding(view.downloadTarget) { view.downloadTarget = nil }) {
                    Button("Download") {
                        if let target = view.downloadTarget?.paperId {
                            view.withNotifications { view.jobs.downloadAudio(target) }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(downloadMessage)
                }
                .alert("Remove this paper?", isPresented: binding(view.removeTarget) { view.removeTarget = nil }) {
                    Button("Remove", role: .destructive) { if let target = view.removeTarget { view.model.removePaper(target) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Deletes \"\(view.removeTarget ?? "")\" and everything saved for it -- progress, notes, cached audio. This can't be undone.")
                }
                .alert("Clear this paper?", isPresented: binding(view.clearTarget) { view.clearTarget = nil }) {
                    Button("Clear", role: .destructive) { if let target = view.clearTarget { view.model.clearPaper(target) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Resets \"\(view.clearTarget ?? "")\" back to the beginning and deletes all its notes. This can't be undone.")
                }
                .alert("Rename paper", isPresented: binding(view.renameTarget) { view.renameTarget = nil }) {
                    TextField("Name", text: view.$renameText)
                    Button("Save") {
                        if let target = view.renameTarget, !view.renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                            view.model.renamePaper(target, view.renameText)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
        }
    }
}
