# Design decisions

The calls made while building the first iOS version, for review. Each one says what was chosen, why,
and what it would take to change.

**Start with these five.** They're the ones you're most likely to want to overrule:

1. [Python runs inside the app](#1-python-runs-inside-the-app): the biggest architectural choice.
2. [What's different from Android](#10-whats-different-from-android): a few features couldn't carry over.
3. [Kokoro's checksum was re-pinned](#8-kokoros-checksum-was-re-pinned): this also found a live Android bug.
4. [Android still has its own copies of the shared code](#3-whats-shared-and-what-isnt).
5. [Nothing has run on an Apple device yet](#12-whats-been-checked-and-what-hasnt).

## Architecture

### 1. Python runs inside the app

**Chosen:** embed real CPython 3.13 using BeeWare's Python-Apple-support (`3.13-b18`), and call
`audiopapers_core` through a small C shim (`Sources/CPythonBridge`) and the same JSON bridge Android
uses (`audiopapers_core/bridge.py`).

**Why:** you asked for as much reuse as possible, and the core is where the product logic lives:
ingest, summaries, questions, notes, voice command parsing and every Gemini call. Android already runs
it this way through Chaquopy, so the two apps can't drift apart. A Swift port would have meant
maintaining that logic twice.

**Rejected:**
- *Port the core to Swift:* it's a second copy of everything, forever.
- *PythonKit:* it adds a dependency for what's about 240 lines of C.
- *A server:* it breaks the free, serverless goal.

**Cost:**
- About 40 MB added to the app, uncompressed. That's added up from the package's files with Python's own
  test suite and a few unused folders removed by `scripts/install-python.sh`, not measured from a built
  app.
- Python starts synchronously at launch.
- Android runs Python 3.10 and iOS 3.13, so the core has to work on both. Its tests pass on both.

**App Store:** CPython 3.13 officially supports iOS and its build is made with App Store rules in mind,
but this app hasn't been through App Review.

### 2. Logic in a package, Apple-only code in the app

**Chosen:** `AudiopapersKit` is a Swift package that uses only Foundation and Observation. It holds the
reading engine, voice controller, mic pipeline, wake word logic and view models. `App/` holds the
SwiftUI screens and thin adapters over Apple's frameworks, behind protocols such as `PlayerBackend`,
`MicSource` and `RecognitionEngine`.

**Why:** there's no Mac here. This split let most of the logic be tested for real on Linux, with the real
Python core. It also matches how the Kotlin code is organised.

### 3. What's shared and what isn't

**Moved into `audiopapers_core`,** ported from Kotlin:
- Markdown parsing for summaries (`client_text.py`).
- Speech text splitting and the yes/no parser (`client_text.py`).
- PDF search queries (`client_text.py`).
- The Kokoro phonemizer and spelling guesser (`phonemizer.py`, `spelling_guesser.py`).
- Model install (`kokoro.py`).
- The voice and model lists (`catalog.json`).

**Android not migrated:** it keeps its Kotlin copies and is otherwise untouched, because you asked for an
iOS version, not an Android refactor, and Android works. It's only additive, and Android's build and unit
tests still pass. Moving Android onto the shared versions would remove the duplication, and is a good
follow-up.

**Stayed in Swift:**
- Real-time audio logic, because it can't wait on Python.
- The reading engine, because it's tied to playback.
- Sentence highlighting, which updates constantly during playback.
- Friendly error messages, which need the local time zone.

**Copied into this repo:** the mascot images, wake word model and test recordings. Sharing them would
have meant reorganising the Android repo.

### 4. Kokoro is split between Python and Swift

**Chosen:** Python turns text into token ids, and Swift runs the model with ONNX Runtime. The model call
has to be native, because ONNX Runtime has no Python build for iOS.

**Trade-off:** the phonemizer and guesser are slower in Python than in Kotlin. The guesser is pure
standard library (no numpy on the phone), at 0.26 s per unknown word on the laptop, and possibly several
times that on a phone. Results are cached per word and most words are in the word list, so I accepted
it. If it's slow in practice, it's the first thing to move to Swift.

### 5. Platform targets

- **iOS 18 minimum**, for `ScrollPosition`, `onScrollPhaseChange` and `@Observable`.
- **iPhone only, portrait only.** The Android app does rotate, so this is a difference. I couldn't look
  at any layouts here, and portrait is the one that matters most. To allow rotation, add the orientations
  in `project.yml`, then check each screen.
- **Swift 5 language mode.** Full Swift 6 strict concurrency was more risk than it was worth without
  a real compiler run on Apple's SDK.
- **Bundle id `com.audiopapers.ios`, version 0.1.**

## Platform choices

### 6. One audio engine for everything

**Chosen:** a single `AVAudioEngine` (`App/Audio/AudioHub.swift`) carries playback, earcons and the mic
tap.

**Why:** Apple's echo cancellation only knows what to subtract if playback goes through the same engine.
"Hey Albert" has to hear you over the paper being read aloud, so this is what makes that possible. It's
also the riskiest audio code, and the part most likely to need tuning on a real phone.

**Details:**
- The session is `.playAndRecord` when the mic is on, and `.playback/.spokenAudio` otherwise.
- When the mic turns off, the engine is replaced. An engine that has touched its input node keeps the
  mic, and can't run in a session that doesn't record. This means playback briefly stops and restarts.
- Android's three `MicMode` values map to voice processing (echo cancelling), mode `.default` (voice
  recognition) and `.measurement` (plain).

### 7. Other platform mappings

| Android | iOS | Notes |
|---|---|---|
| Android `TextToSpeech` | `AVSpeechSynthesizer.write` to a WAV | Rendered the same way, so the player treats it like any other voice. |
| Kokoro on Android ONNX Runtime | `onnxruntime-swift-package-manager` 1.24.2 | Also runs the wake word. |
| `SpeechRecognizer` with device and server routes | `SFSpeechRecognizer`, always fed from the mic pipeline | Tries the device, then the server, replaying captured audio. Android's routes that hand the mic to the recognizer were dropped. |
| Preferences encrypted with Android Keystore | Keychain, after first unlock, this device only | The key doesn't go into backups or to a new phone. |
| Foreground services | Background audio mode, `BGContinuedProcessingTask` on iOS 26, else `beginBackgroundTask` | See section 10 for the limits. |
| Media notification buttons | `MPRemoteCommandCenter` | Feedback commands carry Albert, Describe and Skip. |
| Kokoro download through `HttpURLConnection`, in a worker | Background `URLSession` | iOS finishes it even if the app is suspended. |

Smaller choices:
- Rendered speech is excluded from iCloud backup.
- Python's bytecode cache goes in Caches, since the app bundle is read-only.
- HTTPS uses a bundled `cacert.pem` via `SSL_CERT_FILE`, because embedded Python can't reach the
  system's certificates. Certificates only update with an app update, so bump certifi in
  `scripts/bootstrap.sh` from time to time.
- Reader dialogs are sheets, not alerts, because that's how iOS usually presents these.
- Voice names are shown in Settings, since iOS exposes them.

### 8. Kokoro's checksum was re-pinned

**What happened:** the archive Android pins (`4c30…`, 132,303,094 bytes, verified 2026-10-25) is no longer
what's on GitHub. The project replaced it on 2026-10-26 with `72c3…` (132,353,410 bytes).

**Chosen:** `catalog.json` now pins `72c3…`. This is what iOS uses. Android's own pin is unchanged.

**Why I think it's legitimate:**
- GitHub's API reports the same digest as my two separate downloads.
- The asset's uploader is `csukuangfj`, the account shown on the release asset.
- The archive's README says a 54th voice was added and IDs 0–52 are unchanged. The size of `voices.bin`
  is exactly 54 voices.

**What I couldn't do:** compare it against the old archive, since no copy was left. So this rests on
GitHub's record and the explanation above, not on a byte comparison.

**The Android bug this found:** `KokoroModel.kt` still expects `4c30…`, so a fresh Kokoro download on
Android should now fail with "The downloaded voice didn't match its expected checksum". That's from
reading the code and the hashes, not from running it on a phone. Phones that already have the model
aren't affected. The fix is one line plus a release. I left it for you to decide, as it's outside this
work.

**Longer term:** the app depends on a release file someone else can replace at any time, and when that
happens this feature breaks with no warning. Copying the archive to a release in your own GitHub repo
would stop that, and it's still free and serverless.

### 9. Project and tooling

- **XcodeGen,** with `project.yml` as the source of truth. The generated `.xcodeproj` isn't checked in,
  because it's noisy in diffs and easy to break by hand. This needs one `brew install`.
- **No unofficial copies of Apple's SDK** for checking on Linux, because of the license. The type-check
  uses hand-written stand-ins in `Tools/AppleStubs` instead.
- **Fetched files are pinned by SHA-256** in `scripts/bootstrap.sh` and not checked in.

## Behaviour

### 10. What's different from Android

The mic can only start while the app is on screen, then carries on from there. That's the same on both
platforms.

These differences come from what iOS allows:

| Android | iOS | Why |
|---|---|---|
| Permanent notification with "Stop listening" | No such button. There's the orange mic dot, the voice command and Settings. | iOS has no foreground service notification. |
| A long ingest keeps going in the background | It can be suspended by iOS. If so, it doesn't resume on its own. | iOS limits background work. Pending audio downloads do resume on next open. |
| Download the on-device speech language in the app | A message asking you to turn on Dictation in Settings. | iOS has no API for this. |

These are my calls, and you can overrule them:

| Android | iOS | Why |
|---|---|---|
| Hold a headset button to talk | Dropped. The Albert button on the lock screen does the same job, but nothing on the headset does. | iOS doesn't report a held headset button to apps. |
| Media notification buttons | Feedback commands, labelled Albert, Describe and Skip. | The closest iOS has to custom buttons. How they look on the lock screen needs checking on a device. |
| Rotates | Portrait only. | See section 5. |
| `DebugVoiceReceiver` | Not ported. `actAsIfHeard` is kept for tests. | It relies on `adb`. |
| Wake word gate checked on the mic thread | Checked on the main thread. | Simpler with Swift's isolation. A frame or two of delay doesn't matter here. |

### 11. Everything else follows Android

Screens, wording, settings, defaults and behaviour were ported as closely as I could, including "Hey
Albert" being on by default. If something differs and isn't listed above, it's more likely a mistake than
a decision.

## Verification

### 12. What's been checked and what hasn't

**Nothing has been compiled against Apple's SDK or run on a simulator or device.** There's no Mac here.
Expect some compile errors on the first build: the stand-ins are my reading of Apple's APIs, not the real
thing.

**Checked on Linux, for real:**
- All of `AudiopapersKit`'s tests, running the real Python core.
- The Swift wake word detector with the real ONNX models, against the reference scores from
  `scripts/train_wake_word.py`. The models ran in Python's ONNX Runtime, not the iOS one.
- The shared core on Python 3.10 and 3.13.
- HTTPS with the bundled certificates on 3.13, reaching Gemini.
- The real Kokoro archive installing. The phonemizer's output is byte-identical to Kotlin's on real word
  lists, in US and British English, across five tricky test passages.
- Kokoro rendering speech from the same inputs the Swift code sends, in Python's ONNX Runtime. I checked
  duration and level, and didn't listen to it.

**Checked only for types:** `App/` against the stand-ins. This catches mistakes in our own code, not misuse
of Apple's APIs.

**Never run, riskiest first:**
1. Echo cancellation and `AudioHub` as a whole, including replacing the engine.
2. Speech recognition continuing while the app is in the background.
3. `install_python` packaging and Python starting inside a signed app.
4. ONNX Runtime on iOS. `Tests/AppTests` covers this on a simulator.
5. `BGContinuedProcessingTask`.
6. Animated WebP mascots through `CGAnimateImageAtURLWithBlock`.
7. XcodeGen output, including resources ending up at the bundle root.
8. The CI workflow.
