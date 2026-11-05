import AudiopapersKit
import SwiftUI
import UIKit

/// Everything that lives as long as the app does, put together once at launch. Starting Python
/// happens right here, on the main thread: everything else needs it, and it takes well under the
/// time the launch screen is up.
@MainActor
final class AppServices {
    static private(set) var shared: AppServices?

    let hub: AudioHub
    let micSource: HubMicSource
    let speech: Speech
    let input: SpeechInput
    let engine: ReadingEngine
    let voice: VoiceController
    let jobs: BackgroundJobs
    let home: HomeModel
    let navigator: Navigator
    let kokoroDownloader: KokoroDownloader
    private let nowPlaying: NowPlaying

    init() throws {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let resources = Bundle.main.bundleURL
        Settings.secrets = KeychainSecrets()
        try Core.start(CorePaths(
            pythonHome: resources.appendingPathComponent("python").path,
            appPath: resources.appendingPathComponent("app"),
            pycachePrefix: caches.appendingPathComponent("pycache").path,
            dataDir: support.appendingPathComponent("papers"),
            kokoroRoot: support.appendingPathComponent("kokoro"),
            g2pCheckpoint: resources.appendingPathComponent("checkpoint20.npz"),
            caFile: resources.appendingPathComponent("cacert.pem")
        ))

        let hub = AudioHub()
        let micSource = HubMicSource(hub: hub)
        let speech = Speech(phone: PhoneVoice(), kokoro: KokoroEngine())
        let input = SpeechInput(engine: AppleRecognizer()) {
            MicPipeline(source: micSource, micMode: { Settings.micMode }, createDetector: nil, threshold: { 1 }, onWake: {})
        }
        let notifier = LocalNotifier()
        let navigator = Navigator()
        let jobs = BackgroundJobs(speech: speech, notifier: notifier, runner: SystemBackgroundRunner())
        let engine = ReadingEngine(
            player: hub,
            speech: speech,
            speechInput: input,
            micAllowed: Permissions.micAllowed,
            scratchDir: caches.appendingPathComponent("albert")
        )
        let voice = VoiceController(
            engine: engine,
            speechInput: input,
            navigator: navigator,
            earcons: Earcons(hub: hub),
            notifier: notifier,
            jobs: jobs,
            micAllowed: Permissions.micAllowed,
            makeHandsFreePipeline: { onWake, onProblem in
                MicPipeline(
                    source: micSource,
                    micMode: { Settings.micMode },
                    createDetector: { try WakeModel.detector() },
                    threshold: { Settings.wakeSensitivity.threshold },
                    onWake: onWake,
                    onProblem: onProblem
                )
            }
        )
        self.hub = hub
        self.micSource = micSource
        self.speech = speech
        self.input = input
        self.engine = engine
        self.voice = voice
        self.jobs = jobs
        self.navigator = navigator
        home = HomeModel(jobs: jobs)
        kokoroDownloader = KokoroDownloader()
        nowPlaying = NowPlaying(hub: hub, engine: engine, voice: voice)
        AppServices.shared = self
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The Kokoro download finished while the app wasn't running.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            AppServices.shared?.kokoroDownloader.backgroundCompletion = completionHandler
        }
    }
}

@main
struct AudiopapersApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services = Result { try AppServices() }

    var body: some Scene {
        WindowGroup {
            switch services {
            case .success(let services):
                RootView(services: services).tint(Color("AccentColor"))
            case .failure(let error):
                VStack(spacing: 16) {
                    Text("Audiopapers couldn't start").font(.headline)
                    Text(error.localizedDescription).font(.footnote)
                }
                .padding(24)
            }
        }
    }
}

/// The screens of the app.
enum Route: Hashable {
    case reader(String)
    case summary(String)
    case pdf(String)
    case settings
    case setup
}

/// The navigation stack. A reading session lasts while its reader screen is in the stack: leaving
/// it for good ends the session, and merely backgrounding the app or locking the phone doesn't.
struct RootView: View {
    let services: AppServices
    @State private var path: [Route] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(services: services, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .reader(let paperId): ReaderView(services: services, paperId: paperId, path: $path)
                    case .summary(let paperId): SummaryView(services: services, paperId: paperId)
                    case .pdf(let paperId): PdfScreen(services: services, paperId: paperId)
                    case .settings: SettingsView(services: services, path: $path)
                    case .setup: KeySetupView { _ = path.popLast() }
                    }
                }
        }
        .onChange(of: path) { old, new in
            for case .reader(let paperId) in old where !new.contains(.reader(paperId)) {
                services.engine.close(paperId)
            }
            services.voice.screen = screenName(new.last)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            services.voice.onAppVisible(phase == .active)
            if phase == .active { services.jobs.resumePending() }
        }
        .onChange(of: services.navigator.request, initial: true) { _, request in
            guard let request else { return }
            follow(request)
            services.navigator.handled()
        }
    }

    private func follow(_ request: NavRequest) {
        switch request {
        case .reader(let paperId): path = [.reader(paperId)]
        case .summary(let paperId): path.append(.summary(paperId))
        case .pdf(let paperId): path.append(.pdf(paperId))
        case .settings: path.append(.settings)
        case .back: _ = path.popLast()
        case .home: path = []
        }
    }

    private func screenName(_ route: Route?) -> String {
        switch route {
        case .reader?: return "reader"
        case .summary?: return "summary"
        case .pdf?: return "pdf"
        case .settings?, .setup?: return "settings"
        case nil: return "home"
        }
    }
}
