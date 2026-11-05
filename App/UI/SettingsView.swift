import AudiopapersKit
import AVFoundation
import Observation
import SwiftUI

private let previewText = "This is how papers will sound. Residual networks make very deep models trainable by learning small corrections."
private let minRate: Float = 0.5
private let maxRate: Float = 3
private let rateStep: Float = 0.25

/// The Settings test of "Hey Albert": how it's scoring what the mic hears right now.
struct WakeTest: Equatable {
    var running = false
    var score: Float = 0
    var peak: Float = 0
    var levelDb: Float = -96
    var detections = 0
}

@MainActor
@Observable
final class SettingsModel {
    var voiceEngine = Settings.voiceEngine
    var liveVoiceEngine = Settings.liveVoiceEngine
    var summaryVoiceEngine = Settings.summaryVoiceEngine
    var geminiVoice = Settings.geminiVoice
    var kokoroVoice = Settings.kokoroVoice
    var kokoroInstalled = KokoroModel.isInstalled
    var phoneVoice = Settings.phoneVoice
    let phoneVoices = PhoneVoice.englishVoices()
    var rate = Settings.playbackRate
    var askAboutFigures = Settings.askAboutFigures
    var describeFiguresOnIngest = Settings.describeFiguresOnIngest
    var highlightSpoken = Settings.highlightSpoken
    var followSpoken = Settings.followSpoken
    var heyAlbert = Settings.heyAlbert
    var wakeSensitivity = Settings.wakeSensitivity
    var micMode = Settings.micMode
    var hasKey = Settings.geminiKey != nil
    var textModel = Settings.geminiModel ?? ""
    var ttsModel = Settings.geminiTtsModel ?? ""
    var routerModel = Settings.geminiRouterModel ?? ""
    var audioCacheBytes: Int64 = 0
    var previewing = false
    var message: String?
    var wakeTest = WakeTest()

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: PreviewDelegate?
    @ObservationIgnored private var wakeTestMic: MicPipeline?

    init(services: AppServices) {
        self.services = services
        refreshCacheSize()
    }

    /// Re-reads settings changed elsewhere (the key setup screen).
    func reload() {
        hasKey = Settings.geminiKey != nil
        textModel = Settings.geminiModel ?? ""
    }

    func set(voiceEngine engine: VoiceEngine) {
        Settings.voiceEngine = engine
        voiceEngine = engine
        message = nil
    }

    func set(liveVoiceEngine engine: VoiceEngine) {
        Settings.liveVoiceEngine = engine
        liveVoiceEngine = engine
    }

    func set(summaryVoiceEngine engine: VoiceEngine) {
        Settings.summaryVoiceEngine = engine
        summaryVoiceEngine = engine
    }

    func set(geminiVoice voice: String) {
        Settings.geminiVoice = voice
        geminiVoice = voice
    }

    func set(kokoroVoice voice: String) {
        Settings.kokoroVoice = voice
        kokoroVoice = voice
    }

    func set(phoneVoice voice: String?) {
        Settings.phoneVoice = voice
        phoneVoice = voice
    }

    func setRate(_ wanted: Float) {
        let clamped = max(minRate, min(maxRate, wanted))
        // Through the engine, so a paper that's playing changes speed too.
        services.engine.setRate(clamped)
        rate = clamped
    }

    func set(askAboutFigures on: Bool) {
        Settings.askAboutFigures = on
        askAboutFigures = on
    }

    func set(describeFiguresOnIngest on: Bool) {
        Settings.describeFiguresOnIngest = on
        describeFiguresOnIngest = on
    }

    func set(highlightSpoken on: Bool) {
        Settings.highlightSpoken = on
        highlightSpoken = on
    }

    func set(followSpoken on: Bool) {
        Settings.followSpoken = on
        followSpoken = on
    }

    /// Turning it on also retries every way of hearing.
    func set(heyAlbert on: Bool) {
        Settings.heyAlbert = on
        heyAlbert = on
        if on { services.input.forgetFailures() }
        services.voice.syncListening()
    }

    func set(wakeSensitivity sensitivity: WakeSensitivity) {
        Settings.wakeSensitivity = sensitivity
        wakeSensitivity = sensitivity
    }

    /// Takes effect the next time the mic is opened: restarts a test that's running.
    func set(micMode mode: MicMode) {
        Settings.micMode = mode
        micMode = mode
        if wakeTest.running {
            stopWakeTest()
            startWakeTest()
        }
    }

    func set(textModel model: String) {
        Settings.geminiModel = model
        textModel = model
    }

    func set(ttsModel model: String) {
        Settings.geminiTtsModel = model
        ttsModel = model
    }

    func set(routerModel model: String) {
        Settings.geminiRouterModel = model
        routerModel = model
    }

    func startWakeTest() {
        if wakeTestMic != nil { return }
        wakeTest = WakeTest(running: true)
        let mic = MicPipeline(
            source: services.micSource,
            micMode: { Settings.micMode },
            createDetector: { try WakeModel.detector() },
            threshold: { Settings.wakeSensitivity.threshold },
            onWake: { [weak self] in
                self?.wakeTest.detections += 1
                self?.wakeTestMic?.rearm()
            },
            onLevels: { [weak self] score, level in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.wakeTest.score = score
                        self.wakeTest.peak = max(self.wakeTest.peak, score)
                        self.wakeTest.levelDb = level
                    }
                }
            },
            onProblem: { [weak self] problem in
                self?.stopWakeTest()
                self?.message = problem
            }
        )
        wakeTestMic = mic
        mic.start()
    }

    func stopWakeTest() {
        wakeTestMic?.stop()
        wakeTestMic = nil
        wakeTest = WakeTest()
    }

    /// Plays a short sample in the chosen voice (one Gemini request for a Gemini voice).
    func preview() {
        previewing = true
        message = nil
        let voice = Voice.current()
        services.speech.resumeGemini()
        Task {
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-preview")
                let files = try await services.speech.render(previewText, dir: dir, name: "preview", voice: voice)
                play(files)
            } catch is CancellationError {
                previewing = false
            } catch {
                previewing = false
                message = (error as? LocalizedError)?.errorDescription ?? "Couldn't play a preview"
            }
        }
    }

    /// Plays `files` one after another (the Kokoro voice renders a sample in parts).
    private func play(_ files: [URL]) {
        player?.stop()
        guard let file = files.first else {
            previewing = false
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            if !services.voice.handsFree { try session.setCategory(.playback, mode: .spokenAudio) }
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: file)
            let delegate = PreviewDelegate { [weak self] in self?.play(Array(files.dropFirst())) }
            player.delegate = delegate
            player.play()
            self.player = player
            playerDelegate = delegate
        } catch {
            previewing = false
            message = "Couldn't play a preview"
        }
    }

    func deleteSavedAudio() {
        Task.detached(priority: .utility) { [weak self] in
            for dir in SettingsModel.ttsDirs() { try? FileManager.default.removeItem(at: dir) }
            await self?.refreshCacheSize()
        }
    }

    private nonisolated static func ttsDirs() -> [URL] {
        let papers = (try? FileManager.default.contentsOfDirectory(at: Core.paths.dataDir, includingPropertiesForKeys: nil)) ?? []
        return papers.map { $0.appendingPathComponent("tts") }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func refreshCacheSize() {
        Task.detached(priority: .utility) { [weak self] in
            var total: Int64 = 0
            for dir in SettingsModel.ttsDirs() {
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for file in files {
                    total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            let bytes = total
            await MainActor.run { [weak self] in self?.audioCacheBytes = bytes }
        }
    }
}

private final class PreviewDelegate: NSObject, AVAudioPlayerDelegate {
    private let finished: @MainActor () -> Void

    init(finished: @escaping @MainActor () -> Void) { self.finished = finished }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [finished] in
            MainActor.assumeIsolated { finished() }
        }
    }
}

struct SettingsView: View {
    let services: AppServices
    @Binding var path: [Route]
    @State private var model: SettingsModel?

    var body: some View {
        Group {
            if let model {
                SettingsContent(services: services, model: model, path: $path)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let model { model.reload() } else { model = SettingsModel(services: services) }
        }
        .onDisappear { model?.stopWakeTest() }
    }
}

private struct SettingsContent: View {
    let services: AppServices
    @Bindable var model: SettingsModel
    @Binding var path: [Route]
    @State private var showAdvanced = false

    private var downloader: KokoroDownloader { services.kokoroDownloader }
    private var kokoroMb: Int { KokoroModel.info.downloadMb }
    private var kokoroName: String { "Natural voice on this phone (Kokoro)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings").font(.title2.bold())
                paperVoice
                liveVoice
                summaryVoice
                playback
                Section2("Albert")
                AlbertSettings(services: services, model: model)
                gemini
                Section2("Storage")
                Text("Saved audio: \(formatBytes(model.audioCacheBytes)). Deleting it frees space; audio is made again when you next listen.")
                Button("Delete saved audio") { model.deleteSavedAudio() }
                    .buttonStyle(.bordered)
                    .disabled(model.audioCacheBytes <= 0)
                Section2("About")
                Text("Audiopapers \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.caption)
            }
            .padding(24)
        }
        .onChange(of: downloader.installs) { _, _ in model.kokoroInstalled = KokoroModel.isInstalled }
    }

    private var paperVoice: some View {
        Group {
            Section2("Voice for the paper's text")
            Choice(selected: model.voiceEngine == .phone, title: "Phone voice", detail: "Your phone's built-in text-to-speech. Free and works offline.") {
                model.set(voiceEngine: .phone)
            }
            Choice(
                selected: model.voiceEngine == .gemini,
                title: "Gemini voice",
                detail: "More natural. Needs a connection and uses your Gemini quota: one request per paragraph, so roughly 50 to 150 per paper. Google doesn't publish its free speech limits; if one is hit, the phone voice takes over for the rest of the session.",
                enabled: model.hasKey
            ) {
                model.set(voiceEngine: .gemini)
            }
            if !model.hasKey { Text("Add a Gemini key below to use a Gemini voice.").font(.caption) }
            Choice(
                selected: model.voiceEngine == .kokoro,
                title: kokoroName,
                detail: "Much more natural than the phone voice, free, with no limits, and works offline. Needs a one-time \(kokoroMb) MB download. It's made on the phone, so the first words of each paragraph take a few seconds, and it uses more battery than the phone voice."
            ) {
                model.set(voiceEngine: .kokoro)
            }
            switch model.voiceEngine {
            case .kokoro: kokoroControls
            case .gemini: geminiVoiceMenu
            case .phone: phoneVoiceMenu
            }
            HStack(spacing: 12) {
                Button(model.voiceEngine == .gemini ? "Preview (uses 1 request)" : "Preview") { model.preview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.previewing || (model.voiceEngine == .kokoro && !model.kokoroInstalled))
                if model.previewing { ProgressView() }
            }
            if let message = model.message {
                Text(message).foregroundStyle(.red)
                Button("OK") { model.message = nil }
            }
        }
    }

    private var geminiVoiceMenu: some View {
        let description = Core.catalog.geminiVoices.first { $0.name == model.geminiVoice }?.description ?? ""
        return Menu("Voice: \(model.geminiVoice) (\(description))") {
            ForEach(Core.catalog.geminiVoices) { voice in
                Button("\(voice.name) -- \(voice.description)") { model.set(geminiVoice: voice.name) }
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var phoneVoiceMenu: some View {
        if !model.phoneVoices.isEmpty {
            let label = model.phoneVoices.first { $0.identifier == model.phoneVoice }?.label ?? "Phone's default"
            Menu("Voice: \(label)") {
                Button("Phone's default") { model.set(phoneVoice: nil) }
                ForEach(model.phoneVoices, id: \.identifier) { voice in
                    Button(voice.label) { model.set(phoneVoice: voice.identifier) }
                }
            }
            .buttonStyle(.bordered)
        }
        Text("More voices are in iOS's Settings, under Accessibility, Spoken Content, Voices.").font(.caption)
    }

    @ViewBuilder
    private var kokoroControls: some View {
        switch downloader.state {
        case .running(let done, let total):
            Text("Downloading the voice: \(formatBytes(done))\(total > 0 ? " of \(formatBytes(total))" : ""). This continues if you leave.")
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        case .idle, .failed:
            if !model.kokoroInstalled {
                Text("Until it's downloaded, papers are read with the phone voice.").font(.caption)
                if case .failed(let message) = downloader.state { Text(message).foregroundStyle(.red) }
                Button("Download the voice (\(kokoroMb) MB)") { downloader.start() }.buttonStyle(.borderedProminent)
            }
        }
        if model.kokoroInstalled {
            let label = Core.catalog.kokoroVoice(named: model.kokoroVoice)?.label ?? ""
            Menu("Voice: \(label)") {
                ForEach(Core.catalog.kokoroVoices) { voice in
                    Button(voice.label) { model.set(kokoroVoice: voice.name) }
                }
            }
            .buttonStyle(.bordered)
            Button("Remove the downloaded voice") {
                downloader.cancelAndDelete(speech: services.speech)
                model.kokoroInstalled = false
            }
        }
    }

    private var liveVoice: some View {
        Group {
            Section2("Voice for figures and answers")
            Text("Figure descriptions and answers to your questions are written on the spot, so they can't be prepared ahead. A voice that starts quickly works best here. Each option uses the voice picked for it above.")
                .font(.caption)
            Choice(selected: model.liveVoiceEngine == .phone, title: "Phone voice", detail: "Starts quickly, works offline.") {
                model.set(liveVoiceEngine: .phone)
            }
            Choice(selected: model.liveVoiceEngine == .gemini, title: "Gemini voice", detail: "A few seconds' wait, one request each from your Gemini quota.", enabled: model.hasKey) {
                model.set(liveVoiceEngine: .gemini)
            }
            Choice(selected: model.liveVoiceEngine == .kokoro, title: kokoroName, detail: "Made on the phone as you listen, so expect a pause before each one. Uses the phone voice until Kokoro is downloaded.") {
                model.set(liveVoiceEngine: .kokoro)
            }
        }
    }

    private var summaryVoice: some View {
        Group {
            Section2("Voice for summaries")
            Text("Who reads a paper's summary when you press Play on its summary screen. Each option uses the voice picked for it above.")
                .font(.caption)
            Choice(selected: model.summaryVoiceEngine == .phone, title: "Phone voice", detail: "Starts quickly, works offline.") {
                model.set(summaryVoiceEngine: .phone)
            }
            Choice(selected: model.summaryVoiceEngine == .gemini, title: "Gemini voice", detail: "The whole summary is made before it starts, so expect a wait. One request from your Gemini quota each time the summary changes.", enabled: model.hasKey) {
                model.set(summaryVoiceEngine: .gemini)
            }
            Choice(selected: model.summaryVoiceEngine == .kokoro, title: kokoroName, detail: "Made on the phone as you listen, so expect a pause before it starts. Uses the phone voice until Kokoro is downloaded.") {
                model.set(summaryVoiceEngine: .kokoro)
            }
        }
    }

    private var playback: some View {
        Group {
            Section2("Playback")
            Text("Default reading speed")
            HStack(spacing: 16) {
                Button("−") { model.setRate(model.rate - rateStep) }.buttonStyle(.borderedProminent).disabled(model.rate <= minRate)
                Text("\(model.rate, specifier: "%g")x")
                Button("+") { model.setRate(model.rate + rateStep) }.buttonStyle(.borderedProminent).disabled(model.rate >= maxRate)
            }
            SettingSwitch(
                title: "Offer to describe figures",
                detail: "Pause and ask before describing each figure, table or equation the text mentions. Turn off to keep reading without stopping, e.g. while driving.",
                isOn: Binding(get: { model.askAboutFigures }, set: { model.set(askAboutFigures: $0) })
            )
            SettingSwitch(
                title: "Describe figures while adding a paper",
                detail: "Writes every figure's description up front, so saying yes plays it right away. Adding a paper takes longer and uses a Gemini call per figure.",
                isOn: Binding(get: { model.describeFiguresOnIngest }, set: { model.set(describeFiguresOnIngest: $0) })
            )
            SettingSwitch(
                title: "Highlight the sentence being read",
                detail: "Follows the narration, so it can run a little ahead or behind.",
                isOn: Binding(get: { model.highlightSpoken }, set: { model.set(highlightSpoken: $0) })
            )
            SettingSwitch(
                title: "Scroll to follow the reading",
                detail: "Keeps the sentence being read in view in long paragraphs. Scrolling yourself pauses it for a few seconds.",
                isOn: Binding(get: { model.followSpoken }, set: { model.set(followSpoken: $0) })
            )
        }
    }

    private var gemini: some View {
        Group {
            Section2("Gemini")
            Text(model.hasKey ? "API key saved." : "No API key yet: needed to add papers, describe figures and answer questions.")
            Button(model.hasKey ? "Change or remove key" : "Set up a key") { path.append(.setup) }.buttonStyle(.bordered)
            if showAdvanced || !model.textModel.isEmpty || !model.ttsModel.isEmpty {
                modelField("Model for reading papers and answers (blank = gemini-flash-latest)", Binding(get: { model.textModel }, set: { model.set(textModel: $0) }))
                modelField("Model for the Gemini voice (blank = gemini-3.8-flash-tts)", Binding(get: { model.ttsModel }, set: { model.set(ttsModel: $0) }))
                modelField("Model for voice commands (blank = gemini-3.5-flash-lite)", Binding(get: { model.routerModel }, set: { model.set(routerModel: $0) }))
            } else {
                Button("Advanced: choose models") { showAdvanced = true }
            }
        }
    }

    private func modelField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private struct AlbertSettings: View {
    let services: AppServices
    @Bindable var model: SettingsModel

    var body: some View {
        Group {
            SettingSwitch(
                title: "Listen for \"Hey Albert\"",
                detail: "While a paper is open, even with the screen off, say Hey Albert and then a command or a question. The phrase is picked up on this phone and nothing leaves it until you've said it, but the mic is on, and it uses more battery. It stops if a paper's left paused for half an hour.",
                isOn: Binding(get: { model.heyAlbert }, set: { on in
                    if on {
                        withMic { model.set(heyAlbert: true) }
                    } else {
                        model.set(heyAlbert: false)
                    }
                })
            )
            Text("You can also press the Albert button, whether or not this is on. Try: next, go back, next section, go to the results, pause, faster, what's a residual block, note that the baseline looks wrong, remind me to read this, describe figure three, recap, read my notes. Say help for more.")
                .font(.caption)
            Text("How easily it's set off").fontWeight(.semibold)
            Choice(selected: model.wakeSensitivity == .low, title: "Less often", detail: "If it goes off when you didn't say it.") {
                model.set(wakeSensitivity: .low)
            }
            Choice(selected: model.wakeSensitivity == .normal, title: "Normal", detail: "") {
                model.set(wakeSensitivity: .normal)
            }
            Choice(selected: model.wakeSensitivity == .high, title: "More often", detail: "If it often doesn't hear you, for instance over the car's speakers.") {
                model.set(wakeSensitivity: .high)
            }
            Text("Microphone").fontWeight(.semibold)
            Choice(selected: model.micMode == .echoCancelling, title: "Cancel the phone's own speaker", detail: "Best when narration plays from the phone.") {
                model.set(micMode: .echoCancelling)
            }
            Choice(selected: model.micMode == .voiceRecognition, title: "Tuned for speech", detail: "Try this with headphones or the car's speakers.") {
                model.set(micMode: .voiceRecognition)
            }
            Choice(selected: model.micMode == .plain, title: "Plain", detail: "No processing at all.") {
                model.set(micMode: .plain)
            }
            Text("Test it").fontWeight(.semibold)
            if model.wakeTest.running {
                Text("Say \"Hey Albert\". It counts as heard from \(Int(model.wakeSensitivity.threshold * 100))% on the bar.").font(.caption)
                ProgressView(value: Double(model.wakeTest.score))
                Text("Heard it \(model.wakeTest.detections) times. Best score \(Int(model.wakeTest.peak * 100))%. Mic level \(Int(model.wakeTest.levelDb)) dB.").font(.caption)
                Button("Stop test") { model.stopWakeTest() }.buttonStyle(.bordered)
            } else {
                Button("Test \"Hey Albert\"") { withMic { model.startWakeTest() } }
                    .buttonStyle(.bordered)
                    .disabled(services.voice.handsFree)
            }
        }
    }
}

private struct SettingSwitch: View {
    let title: String
    let detail: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption)
            }
        }
    }
}

private struct Section2: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(title).font(.headline)
        }
        .padding(.top, 8)
    }
}

private struct Choice: View {
    let selected: Bool
    let title: String
    let detail: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                VStack(alignment: .leading) {
                    Text(title).fontWeight(.semibold).foregroundStyle(.primary)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .disabled(!enabled)
    }
}
