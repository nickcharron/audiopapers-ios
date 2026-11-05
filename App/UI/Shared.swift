import AudiopapersKit
import ImageIO
import SwiftUI
import UIKit

/// The app's reading-session states that have a mascot clip. `loopOnce` plays once and holds the
/// last frame rather than repeating; the files themselves all claim "loop forever" in their own
/// metadata, so this is enforced at playback time instead of trusting the file.
enum MascotState: String {
    // Default "narrating a section" state: loops for as long as playback continues.
    case reading = "mascot_reading"
    // Paused: the clip plays a pause-icon -> eyes-close -> "Zzz" sequence once and ends mid-doze.
    case sleeping = "mascot_sleeping"
    // Shown only while the "Add a note" sheet is open.
    case takingNotes = "mascot_taking_notes"
    // Home screen's hero clip, idle/welcoming.
    case home = "mascot_home"
    // Home screen while a picked PDF is ingesting. One-shot: it builds into a full "processing"
    // effect and ends there.
    case ingesting = "mascot_ingesting"
    // Taking in what's being said to Albert.
    case listening = "mascot_listening"
    // Working out an answer.
    case thinking = "mascot_thinking"

    var loopOnce: Bool { self == .sleeping || self == .ingesting }
}

/// A small transparent mascot clip: an animated WebP with per-pixel alpha, played by ImageIO.
struct MascotView: UIViewRepresentable {
    let state: MascotState

    final class Coordinator {
        var playing: MascotState?
        var generation = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.playing != state else { return }
        coordinator.playing = state
        coordinator.generation += 1
        let generation = coordinator.generation
        guard let url = Bundle.main.url(forResource: state.rawValue, withExtension: "webp") else { return }
        var options: [CFString: Any] = [:]
        if state.loopOnce { options[kCGImageAnimationLoopCount] = 1 }
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, options as CFDictionary) { [weak view, weak coordinator] _, image, stop in
            guard let view, let coordinator, coordinator.generation == generation else {
                stop.pointee = true
                return
            }
            view.image = UIImage(cgImage: image)
        }
        if status != noErr {
            // Not worth failing over: the first frame is still the right picture.
            view.image = UIImage(contentsOfFile: url.path)
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.generation += 1
    }
}

/// A figure/table/equation cropped from the paper's PDF (see FigureCropper); shows nothing until the
/// crop is ready, or at all if the item has no recorded position.
struct FigureImage: View {
    let paperId: String
    let figureId: String
    let label: String
    let maxHeight: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(label)
            }
        }
        .task(id: "\(paperId)/\(figureId)") {
            let url = try? await FigureCropper.crop(paperId: paperId, figureId: figureId)
            image = url.flatMap { UIImage(contentsOfFile: $0.path) }
        }
    }
}

/// A small per-paper status badge for the home screen's "Resume paper" list -- grey/hollow (not
/// started), yellow with a progress arc (in progress), or a solid green disc (done). Progress is by
/// section, the same granularity the reader's "Section X/Y" shows.
struct PaperStatusRing: View {
    let sectionIndex: Int
    let segmentIndex: Int
    let totalSections: Int
    let done: Bool

    var body: some View {
        let notStarted = !done && sectionIndex == 0 && segmentIndex == 0
        let progress = totalSections > 0 ? min(1, max(0, Double(sectionIndex) / Double(totalSections))) : 0
        ZStack {
            if done {
                Circle().fill(Color(red: 0x34 / 255, green: 0xA8 / 255, blue: 0x53 / 255))
            } else if notStarted {
                Circle().stroke(Color(red: 0x9A / 255, green: 0xA0 / 255, blue: 0xA6 / 255), lineWidth: 3)
            } else {
                Circle().fill(Color(red: 1, green: 0xF3 / 255, blue: 0xC4 / 255))
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color(red: 0xF2 / 255, green: 0xB7 / 255, blue: 0x05 / 255), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(done ? "Done" : notStarted ? "Not started" : "In progress")
    }
}

/// Says something to Albert without saying "Hey Albert" first.
struct AlbertButton: View {
    let voiceState: VoiceState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(voiceState.isHearing ? "Done" : "Albert", systemImage: "mic.fill")
        }
        .buttonStyle(.bordered)
    }
}

/// A line saying what Albert's doing, when it isn't obvious from the rest of the screen, and what it
/// last heard, which is how to tell a misheard command from a misunderstood one.
struct AlbertStatus: View {
    let voiceState: VoiceState
    let heard: String?

    private var status: String? {
        switch voiceState {
        case .off, .hearing: return nil // the words themselves are shown where they matter
        case .waiting: return "Listening for \"Hey Albert\""
        case .understanding: return "Working that out..."
        case .confirming: return "Say yes or no"
        }
    }

    var body: some View {
        if let status {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        if let heard {
            Text("Heard \"\(heard)\"").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Asks for the mic and speech recognition if need be, then carries on if they were allowed.
@MainActor
func withMic(_ action: @escaping @MainActor () -> Void) {
    if Permissions.micAllowed() {
        action()
    } else {
        Task {
            if await Permissions.requestMicAndSpeech() { action() }
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return "\(bytes / 1_000) KB" }
    return "\(bytes) bytes"
}
