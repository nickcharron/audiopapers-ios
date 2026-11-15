import Foundation

/// Who reads aloud.
public enum VoiceEngine: String, CaseIterable, Sendable {
    case phone = "PHONE"
    case gemini = "GEMINI"
    case kokoro = "KOKORO"
}

/// How readily "Hey Albert" counts as heard: the wake-word model's score it has to reach, chosen
/// from the table in the main repo's docs/hey_albert.report.md.
public enum WakeSensitivity: String, CaseIterable, Sendable {
    case low = "LOW"
    case normal = "NORMAL"
    case high = "HIGH"

    public var threshold: Float {
        Core.catalog.wakeSensitivity[rawValue.lowercased()] ?? 0.1
    }
}

/// What the microphone listens through while waiting for "Hey Albert". Which works best depends
/// on the phone and how it's being listened on, so it's a setting.
public enum MicMode: String, CaseIterable, Sendable {
    /// The phone's own echo cancelling, so its speaker's narration is less in the way.
    case echoCancelling = "ECHO_CANCELLING"
    case voiceRecognition = "VOICE_RECOGNITION"
    case plain = "PLAIN"
}

/// Keeps the Gemini key. In the Keychain in the app.
public protocol SecretStore: Sendable {
    func read(_ name: String) -> String?
    func write(_ name: String, _ value: String?)
}

/// App settings: the user's own Gemini API key (bring your own key: the app pays for nothing),
/// model overrides, the reading voice, speed, and whether to ask about figures.
public enum Settings {
    public static var defaults: UserDefaults = .standard
    public static var secrets: SecretStore!

    private static func text(_ key: String) -> String? { defaults.string(forKey: key) }

    private static func setTrimmed(_ value: String?, _ key: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(trimmed, forKey: key) }
    }

    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    public static var geminiKey: String? {
        get { secrets.read("gemini_key") }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            secrets.write("gemini_key", trimmed.isEmpty ? nil : trimmed)
        }
    }

    /// Nil means audiopapers_core's default ("gemini-flash-latest").
    public static var geminiModel: String? {
        get { text("gemini_model") }
        set { setTrimmed(newValue, "gemini_model") }
    }

    /// Who reads papers aloud: the phone's own text-to-speech, a Gemini voice, or the on-device
    /// Kokoro voice.
    public static var voiceEngine: VoiceEngine {
        get { text("voice_engine").flatMap(VoiceEngine.init) ?? .phone }
        set { defaults.set(newValue.rawValue, forKey: "voice_engine") }
    }

    /// Who speaks what's made on the spot -- figure descriptions and answers to questions. The
    /// phone voice by default: it starts quickly, where Kokoro would make the listener wait for
    /// each one to render. Uses the same voice picked for each engine.
    public static var liveVoiceEngine: VoiceEngine {
        get { text("live_voice_engine").flatMap(VoiceEngine.init) ?? .phone }
        set { defaults.set(newValue.rawValue, forKey: "live_voice_engine") }
    }

    /// Who reads a paper's summary aloud. The phone voice by default, for the same reason as
    /// `liveVoiceEngine`. Uses the same voice picked for each engine.
    public static var summaryVoiceEngine: VoiceEngine {
        get { text("summary_voice_engine").flatMap(VoiceEngine.init) ?? .phone }
        set { defaults.set(newValue.rawValue, forKey: "summary_voice_engine") }
    }

    public static var geminiVoice: String {
        get { text("gemini_voice") ?? Core.catalog.defaultGeminiVoice }
        set { defaults.set(newValue, forKey: "gemini_voice") }
    }

    /// The phone text-to-speech voice's identifier; nil means the system's default voice.
    public static var phoneVoice: String? {
        get { text("phone_voice") }
        set { defaults.set(newValue, forKey: "phone_voice") }
    }

    public static var kokoroVoice: String {
        get {
            if let saved = text("kokoro_voice"), Core.catalog.kokoroVoice(named: saved) != nil { return saved }
            return Core.catalog.defaultKokoroVoice
        }
        set { defaults.set(newValue, forKey: "kokoro_voice") }
    }

    /// Nil means audiopapers_core's default speech model.
    public static var geminiTtsModel: String? {
        get { text("gemini_tts_model") }
        set { setTrimmed(newValue, "gemini_tts_model") }
    }

    /// Reading speed, kept between sessions.
    public static var playbackRate: Float {
        get { defaults.object(forKey: "playback_rate") == nil ? 1 : defaults.float(forKey: "playback_rate") }
        set { defaults.set(newValue, forKey: "playback_rate") }
    }

    /// Whether the reader highlights the sentence being read.
    public static var highlightSpoken: Bool {
        get { flag("highlight_spoken", default: true) }
        set { defaults.set(newValue, forKey: "highlight_spoken") }
    }

    /// Whether the reader scrolls a long paragraph to keep the sentence being read in view.
    public static var followSpoken: Bool {
        get { flag("follow_spoken", default: true) }
        set { defaults.set(newValue, forKey: "follow_spoken") }
    }

    /// Whether to stop and offer to describe each figure/table/equation the text mentions.
    public static var askAboutFigures: Bool {
        get { flag("ask_about_figures", default: true) }
        set { defaults.set(newValue, forKey: "ask_about_figures") }
    }

    /// Whether adding a paper also writes every figure's description, so "yes" to a describe
    /// prompt plays at once instead of waiting on Gemini. Off by default: it spends a Gemini call
    /// per figure, including ones never asked about.
    public static var describeFiguresOnIngest: Bool {
        get { flag("describe_figures_on_ingest", default: false) }
        set { defaults.set(newValue, forKey: "describe_figures_on_ingest") }
    }

    /// Whether to listen for "Hey Albert" while a paper is open. It means the mic is on, though
    /// nothing leaves the phone until the phrase has been heard.
    public static var heyAlbert: Bool {
        get { flag("hey_albert", default: true) }
        set { defaults.set(newValue, forKey: "hey_albert") }
    }

    /// Whether questions and notes go on through pauses until "over" is said, rather than ending at
    /// the first pause. Commands still end at a pause.
    public static var sayOver: Bool {
        get { flag("say_over", default: true) }
        set { defaults.set(newValue, forKey: "say_over") }
    }

    public static var wakeSensitivity: WakeSensitivity {
        get { text("wake_sensitivity").flatMap(WakeSensitivity.init) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "wake_sensitivity") }
    }

    public static var micMode: MicMode {
        get { text("mic_mode").flatMap(MicMode.init) ?? .echoCancelling }
        set { defaults.set(newValue.rawValue, forKey: "mic_mode") }
    }

    /// The model for working out what a spoken command means, when the fixed phrases don't cover
    /// it. Nil means audiopapers_core's default.
    public static var geminiRouterModel: String? {
        get { text("gemini_router_model") }
        set { setTrimmed(newValue, "gemini_router_model") }
    }

    /// Ways of hearing that have kept failing on this phone (SpeechInput).
    public static var brokenSpeechRoutes: Set<String> {
        get { Set(defaults.stringArray(forKey: "broken_speech_routes") ?? []) }
        set { defaults.set(Array(newValue), forKey: "broken_speech_routes") }
    }
}
