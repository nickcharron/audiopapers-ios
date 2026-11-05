import AudiopapersKit
import AVFoundation
import Foundation

private let inputTapFrames: AVAudioFrameCount = 4096

/// The one AVAudioEngine: narration, Albert's little sounds and the microphone all go through it.
/// Sharing it is what lets echo cancelling know what the phone itself is playing, so "Hey Albert"
/// can be heard over narration from the speaker. Implements the player ReadingEngine drives: a list
/// of files played in order, at a rate that doesn't change their pitch.
@MainActor
final class AudioHub: PlayerBackend {
    var playWhenReady = true
    private(set) var isPlaying = false
    private(set) var state = PlayerState.idle
    private(set) var currentIndex = 0

    var onIsPlayingChanged: ((Bool) -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    /// The item or its title changed, for the lock screen.
    var onNowPlayingChanged: (() -> Void)?

    private var engine = AVAudioEngine()
    /// Whether this engine has touched its input node, after which it holds on to the mic.
    private var engineHasInput = false
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let earconNode = AVAudioPlayerNode()
    private let earconFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private var items: [PlayerItem] = []
    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    /// Where in the file the scheduled segment starts, since the node counts from there.
    private var startFrame: AVAudioFramePosition = 0
    /// Where playback was when the engine last let go of it.
    private var heldFrame: AVAudioFramePosition = 0
    /// Bumped whenever what's scheduled changes, so a stale completion is recognised.
    private var generation = 0
    private var rate: Float = 1

    private var micOn = false
    private var micMode = MicMode.echoCancelling
    private let delivery = MicDelivery()
    private let micQueue = DispatchQueue(label: "audiopapers.mic", qos: .userInitiated)
    private var tapInstalled = false

    private var resumeAfterInterruption = false

    init() {
        attachNodes()

        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated { self?.onInterruption(type, shouldResume: options?.contains(.shouldResume) == true) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones or Bluetooth went away: don't carry on out loud from the speaker.
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            let changed = note.object as AnyObject?
            MainActor.assumeIsolated {
                if let self, changed === self.engine { self.onConfigurationChange() }
            }
        }
    }

    private func attachNodes() {
        engine.attach(node)
        engine.attach(timePitch)
        engine.attach(earconNode)
        engine.connect(earconNode, to: engine.mainMixerNode, format: earconFormat)
    }

    /// The only way to really let go of the mic: an engine that's touched its input node keeps it,
    /// and can't run in a session that doesn't record.
    private func replaceEngine() {
        engine.stop()
        engine.detach(node)
        engine.detach(timePitch)
        engine.detach(earconNode)
        engine = AVAudioEngine()
        engineHasInput = false
        connectedFormat = nil
        attachNodes()
    }

    // MARK: - PlayerBackend

    var itemCount: Int { items.count }

    var currentItem: PlayerItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }

    private var currentFrame: AVAudioFramePosition {
        guard let file else { return 0 }
        var frame = heldFrame
        if isPlaying, let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) {
            frame = startFrame + max(playerTime.sampleTime, 0)
        }
        return min(frame, file.length)
    }

    var currentPositionMs: Int64 {
        guard let file else { return 0 }
        return Int64(Double(currentFrame) / file.processingFormat.sampleRate * 1000)
    }

    var durationMs: Int64 {
        guard let file else { return 0 }
        return Int64(Double(file.length) / file.processingFormat.sampleRate * 1000)
    }

    func setItems(_ items: [PlayerItem], index: Int, positionMs: Int64) {
        self.items = items
        load(index: index, positionMs: positionMs)
    }

    func addItem(_ item: PlayerItem) {
        items.append(item)
    }

    func seek(index: Int, positionMs: Int64) {
        load(index: index, positionMs: positionMs)
    }

    func play() {
        playWhenReady = true
        guard file != nil, state != .ended else { return }
        guard startEngineIfNeeded() else { return }
        node.play()
        setPlaying(true)
    }

    func pause() {
        playWhenReady = false
        holdPosition()
        if isPlaying { node.pause() }
        setPlaying(false)
        // Nothing to run for, so the app can be put to sleep. A paper left paused with "Hey Albert"
        // on stays awake, since the mic needs it.
        if !micOn { engine.pause() }
    }

    func stop() {
        generation += 1
        node.stop()
        items = []
        file = nil
        currentIndex = 0
        startFrame = 0
        heldFrame = 0
        state = .idle
        setPlaying(false)
        if !micOn {
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        onNowPlayingChanged?()
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        timePitch.rate = rate
        onNowPlayingChanged?()
    }

    var playbackRate: Float { rate }

    func setCurrentTitle(_ title: String) {
        if items.indices.contains(currentIndex) {
            items[currentIndex].title = title
            onNowPlayingChanged?()
        }
    }

    // MARK: - Playing one file

    private func setPlaying(_ playing: Bool) {
        if playing != isPlaying {
            isPlaying = playing
            onIsPlayingChanged?(playing)
            onNowPlayingChanged?()
        }
    }

    private func holdPosition() {
        heldFrame = currentFrame
    }

    /// Opens the item and schedules it from `positionMs`, playing it if that's wanted.
    private func load(index: Int, positionMs: Int64) {
        guard items.indices.contains(index) else { return }
        generation += 1
        node.stop()
        currentIndex = index
        let opened: AVAudioFile
        do {
            opened = try AVAudioFile(forReading: items[index].url)
        } catch {
            file = nil
            state = .idle
            setPlaying(false)
            onError?("Couldn't open the audio (\(error.localizedDescription))")
            return
        }
        file = opened
        state = .ready
        let format = opened.processingFormat
        if connectedFormat != format {
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(node, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        guard startEngineIfNeeded() else { return }
        timePitch.rate = rate
        startFrame = min(AVAudioFramePosition(Double(positionMs) / 1000 * format.sampleRate), opened.length)
        heldFrame = startFrame
        let frames = AVAudioFrameCount(max(opened.length - startFrame, 0))
        if frames == 0 {
            itemFinished()
            return
        }
        node.scheduleSegment(
            opened,
            startingFrame: startFrame,
            frameCount: frames,
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: AudioHub.completion(hub: self, generation: generation)
        )
        if playWhenReady {
            node.play()
            setPlaying(true)
        } else {
            setPlaying(false)
        }
        onNowPlayingChanged?()
    }

    /// Made outside the main actor, since the player node calls this on its own thread.
    private nonisolated static func completion(hub: AudioHub, generation: Int) -> AVAudioPlayerNodeCompletionHandler {
        { [weak hub] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let hub, hub.generation == generation else { return }
                    hub.itemFinished()
                }
            }
        }
    }

    private func itemFinished() {
        if currentIndex + 1 < items.count {
            load(index: currentIndex + 1, positionMs: 0)
        } else {
            heldFrame = file?.length ?? 0
            state = .ended
            setPlaying(false)
            onEnded?()
        }
    }

    // MARK: - The engine and the session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        if micOn {
            // Bluetooth stays on A2DP, so a car or earbuds keep their sound quality and the phone's
            // own mic does the listening.
            let mode: AVAudioSession.Mode = micMode == .plain ? .measurement : .default
            try session.setCategory(.playAndRecord, mode: mode, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio)
        }
        try session.setActive(true)
    }

    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do {
            try configureSession()
            engine.prepare()
            try engine.start()
            return true
        } catch {
            Log.e("Couldn't start audio: \(error)")
            setPlaying(false)
            onError?("Couldn't start audio (\(error.localizedDescription))")
            return false
        }
    }

    /// Rebuilds the engine for what's wanted now, carrying on from where playback was. Changing
    /// the session or echo cancelling needs the engine stopped.
    private func reconfigure() throws {
        let wasPlaying = isPlaying
        holdPosition()
        let position = currentPositionMs
        removeTap()
        engine.stop()
        if !micOn && engineHasInput { replaceEngine() }
        try configureSession()
        if micOn {
            engineHasInput = true
            try engine.inputNode.setVoiceProcessingEnabled(micMode == .echoCancelling)
            try installTap()
        }
        engine.prepare()
        try engine.start()
        if file != nil {
            let wanted = playWhenReady
            playWhenReady = wasPlaying
            load(index: currentIndex, positionMs: position)
            playWhenReady = wanted
        }
    }

    private func onConfigurationChange() {
        // A route change stops the engine by itself. Ones this causes leave it running.
        guard !engine.isRunning, micOn || isPlaying else { return }
        do {
            try reconfigure()
        } catch {
            Log.e("Couldn't restart audio after a change: \(error)")
            onError?("Lost the audio after a change of route.")
        }
    }

    private func onInterruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            holdPosition()
            setPlaying(false)
        case .ended:
            guard micOn || resumeAfterInterruption else { return }
            let resume = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            if micOn {
                try? reconfigure()
            }
            if resume { play() }
        default:
            break
        }
    }

    // MARK: - The microphone

    func startMic(mode: MicMode, onSamples: @escaping ([Int16]) -> Void) throws {
        delivery.setSink(onSamples)
        if micOn && micMode == mode && engine.isRunning && tapInstalled { return }
        micOn = true
        micMode = mode
        do {
            try reconfigure()
        } catch {
            micOn = false
            delivery.setSink(nil)
            throw error
        }
    }

    func stopMic() {
        guard micOn else { return }
        micOn = false
        delivery.setSink(nil)
        do {
            try reconfigure()
            // Nothing else is keeping it running.
            if !isPlaying && file == nil {
                engine.stop()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        } catch {
            Log.w("Couldn't let go of the microphone cleanly: \(error)")
        }
    }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechFailure("The microphone isn't available.")
        }
        guard let converter = MicConverter(inputRate: format.sampleRate) else {
            throw SpeechFailure("Couldn't read the microphone's format.")
        }
        input.installTap(onBus: 0, bufferSize: inputTapFrames, format: format, block: AudioHub.tap(delivery: delivery, queue: micQueue, converter: converter))
        tapInstalled = true
    }

    private func removeTap() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    /// Made outside the main actor, since the engine calls this on its own thread. The first
    /// channel is what's used: with echo cancelling on, that's the processed one.
    private nonisolated static func tap(delivery: MicDelivery, queue: DispatchQueue, converter: MicConverter) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            queue.async {
                let converted = converter.convert(samples)
                if !converted.isEmpty { delivery.send(converted) }
            }
        }
    }

    // MARK: - Earcons

    func playTone(hertz: [Double], seconds: Double) {
        let frameCount = AVAudioFrameCount(seconds * earconFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: earconFormat, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0],
              !hertz.isEmpty else { return }
        buffer.frameLength = frameCount
        let perTone = Int(frameCount) / hertz.count
        let fade = Double(min(perTone / 4, 400))
        for i in 0..<Int(frameCount) {
            let tone = min(i / max(perTone, 1), hertz.count - 1)
            let within = i - tone * perTone
            let envelope = min(1, min(Double(within), Double(perTone - within)) / max(fade, 1))
            channel[i] = Float(sin(2 * Double.pi * hertz[tone] * Double(i) / earconFormat.sampleRate) * 0.25 * envelope)
        }
        guard startEngineIfNeeded() else { return }
        earconNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        earconNode.play()
    }
}

/// Hands the mic's audio on, on the mic's queue, to whichever pipeline is listening.
private final class MicDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (([Int16]) -> Void)?

    func setSink(_ sink: (([Int16]) -> Void)?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func send(_ samples: [Int16]) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?(samples)
    }
}

/// The microphone as a MicSource for MicPipeline. Pipelines are only ever started and stopped on
/// the main thread.
final class HubMicSource: MicSource, @unchecked Sendable {
    private let hub: AudioHub

    init(hub: AudioHub) { self.hub = hub }

    func start(mode: MicMode, onSamples: @escaping ([Int16]) -> Void) throws {
        try MainActor.assumeIsolated { try hub.startMic(mode: mode, onSamples: onSamples) }
    }

    func stop() {
        MainActor.assumeIsolated { hub.stopMic() }
    }
}

/// Whatever rate the hardware runs at, to the 16 kHz mono 16-bit the wake word and recognizer take.
final class MicConverter: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputRate: Double) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(micSampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        inputFormat = input
        outputFormat = output
        self.converter = converter
    }

    func convert(_ samples: [Float]) -> [Int16] {
        guard !samples.isEmpty,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = inputBuffer.floatChannelData?[0] else { return [] }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * outputFormat.sampleRate / inputFormat.sampleRate) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, let output = outputBuffer.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: output, count: Int(outputBuffer.frameLength)))
    }
}
