import Foundation

private let ringSeconds = 4
// How long before "Hey Albert" fired the recognizer's audio starts: the phrase's model fires a
// little after its last word, and the command may already have begun by then.
private let wakePreRollSamples = micSampleRate * 2 / 5
// Otherwise a moment's worth, for someone already talking when the mic was handed over.
private let defaultPreRollSamples = micSampleRate / 5
private let healthEverySeconds: TimeInterval = 10

/// Where microphone audio comes from: 16 kHz mono, in pieces of any size, on one background queue.
public protocol MicSource: AnyObject {
    func start(mode: MicMode, onSamples: @escaping ([Int16]) -> Void) throws
    func stop()
}

/// The one place the microphone is listened to: audio from a MicSource feeds a rolling buffer and
/// the wake-word detector, and (while a command is being heard) the speech recognizer through
/// `startStreaming`. The wake-word test in Settings runs its own.
public final class MicPipeline: @unchecked Sendable {
    private let source: MicSource
    private let micMode: () -> MicMode
    private let createDetector: (() throws -> WakeDetector)?
    private let threshold: () -> Float
    private let onWake: @MainActor () -> Void
    private let onLevels: ((_ score: Float, _ levelDb: Float) -> Void)?
    private let onProblem: @MainActor (String) -> Void

    private let lock = NSLock()
    private let ring = PcmRing(capacity: micSampleRate * ringSeconds)
    private let trigger = WakeTrigger()

    // Guarded by lock.
    private var running = false
    private var sink: (([Int16]) -> Void)?
    private var detecting = true
    private var samplesSinceWake = -1

    // Only touched from the source's queue.
    private var pending: [Int16] = []
    private var detector: WakeDetector?
    private var detectorTried = false
    private var healthFrames = 0
    private var healthSince = Date()
    private var healthBestScore: Float = 0
    private var healthLoudest: Float = -96

    /// `createDetector` nil means only ever hearing what's said, never listening for the phrase.
    public init(
        source: MicSource,
        micMode: @escaping () -> MicMode,
        createDetector: (() throws -> WakeDetector)?,
        threshold: @escaping () -> Float,
        onWake: @escaping @MainActor () -> Void,
        onLevels: ((_ score: Float, _ levelDb: Float) -> Void)? = nil,
        onProblem: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.source = source
        self.micMode = micMode
        self.createDetector = createDetector
        self.threshold = threshold
        self.onWake = onWake
        self.onLevels = onLevels
        self.onProblem = onProblem
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        do {
            try source.start(mode: micMode()) { [weak self] samples in self?.feed(samples) }
        } catch {
            Log.w("Couldn't open the microphone: \(error)")
            lock.lock()
            running = false
            lock.unlock()
            let problem = onProblem
            Task { @MainActor in problem("Couldn't open the microphone.") }
        }
    }

    /// Stops listening and lets the mic go.
    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        sink = nil
        lock.unlock()
        if wasRunning { source.stop() }
    }

    /// Sends audio to `onFrame` from now on (on the source's queue), starting with what came just
    /// before. Wake-word detection pauses until `stopStreaming`.
    public func startStreaming(fromWake: Bool, onFrame: @escaping ([Int16]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let preRoll = fromWake && samplesSinceWake >= 0 ? samplesSinceWake + wakePreRollSamples : defaultPreRollSamples
        detecting = false
        let earlier = ring.latest(min(preRoll, ring.capacity))
        if !earlier.isEmpty { onFrame(earlier) }
        sink = onFrame
    }

    public func stopStreaming() {
        lock.lock()
        defer { lock.unlock() }
        sink = nil
        detecting = true
        samplesSinceWake = -1
        trigger.reset()
    }

    /// Goes back to listening for the wake word after one fired and nothing came of it.
    public func rearm() { stopStreaming() }

    /// Roughly how loud it's been between words lately.
    public func quietLevelDb() -> Float {
        lock.lock()
        let recent = ring.latest(ring.capacity)
        lock.unlock()
        var levels: [Float] = []
        var at = 0
        while at + micFrameSamples <= recent.count {
            levels.append(SpeechEndpointer.levelDb(Array(recent[at..<(at + micFrameSamples)])))
            at += micFrameSamples
        }
        levels.sort()
        return levels.isEmpty ? .nan : levels[levels.count / 5]
    }

    /// Takes audio from the source, a frame's worth at a time.
    func feed(_ samples: [Int16]) {
        pending.append(contentsOf: samples)
        var at = 0
        while pending.count - at >= micFrameSamples {
            process(Array(pending[at..<(at + micFrameSamples)]))
            at += micFrameSamples
        }
        if at > 0 { pending.removeFirst(at) }
    }

    private func loadedDetector() -> WakeDetector? {
        if detectorTried { return detector }
        detectorTried = true
        guard let createDetector else { return nil }
        do {
            detector = try createDetector()
        } catch {
            Log.e("Couldn't load the wake-word model: \(error)")
            let problem = onProblem
            Task { @MainActor in problem("Couldn't load the wake word model, so saying Hey Albert won't work.") }
        }
        return detector
    }

    private func process(_ frame: [Int16]) {
        // Kept fed even while a command is being heard, so it's ready the moment that's over.
        var score: Float = 0
        do {
            score = try loadedDetector()?.score(frame) ?? 0
        } catch {
            Log.w("Wake-word model failed on a frame: \(error)")
        }
        let level = SpeechEndpointer.levelDb(frame)
        onLevels?(score, level)
        logHealth(score: score, level: level)
        var fire = false
        lock.lock()
        ring.write(frame)
        sink?(frame)
        if samplesSinceWake >= 0 { samplesSinceWake += frame.count }
        if detecting && trigger.feed(score, threshold: threshold()) {
            detecting = false
            samplesSinceWake = 0
            fire = true
        }
        lock.unlock()
        if fire {
            let wake = onWake
            Task { @MainActor in wake() }
        }
    }

    /// A line in the log now and then, to tell "the mic hears nothing" from "the model isn't
    /// convinced" from "it can't keep up" when trying this on a new phone.
    private func logHealth(score: Float, level: Float) {
        let now = Date()
        if healthFrames == 0 { healthSince = now }
        healthFrames += 1
        healthBestScore = max(healthBestScore, score)
        healthLoudest = max(healthLoudest, level)
        let elapsed = now.timeIntervalSince(healthSince)
        if elapsed >= healthEverySeconds {
            let realTime = Double(healthFrames * micFrameSamples) / Double(micSampleRate) / elapsed
            Log.d("Mic: \(String(format: "%.2f", realTime))x real time, loudest \(Int(healthLoudest)) dB, best wake score \(String(format: "%.3f", healthBestScore))")
            healthFrames = 0
            healthBestScore = 0
            healthLoudest = -96
        }
    }
}
