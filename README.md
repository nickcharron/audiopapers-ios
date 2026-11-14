# Audiopapers for iOS

The iPhone version of Audiopapers, made to match [audiopapers-android](https://github.com/nickcharron/audiopapers-android).
It reads research papers aloud, and you can ask about them, take notes and control it by voice with "Hey
Albert". It's free and has no server: everything runs on the phone with your own Gemini key.

**Status: first version, not yet run on an iPhone.** It builds on GitHub's macOS runners and passes its
simulator tests, but the microphone, echo cancelling, background listening and the lock screen still need
a real phone. See
[What's been checked](DESIGN_DECISIONS.md#12-whats-been-checked-and-what-hasnt).

[DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) explains the choices behind it and how it differs from Android.

## Build it

You need a Mac with Xcode 16 or newer, and the
[audiopapers](https://github.com/nickcharron/audiopapers) repo checked out beside this one. The app bundles
`audiopapers_core` from there. Set `AUDIOPAPERS_REPO` if it lives somewhere else.

```bash
scripts/bootstrap.sh                          # fetches Python and the models, each checked against a hash
brew install xcodegen && xcodegen generate    # makes Audiopapers.xcodeproj
open Audiopapers.xcodeproj
```

Then pick your team under Signing & Capabilities, choose a device or simulator, and run it.

Run the tests from Xcode, or with:

```bash
xcodebuild test -project Audiopapers.xcodeproj -scheme Audiopapers \
    -destination 'platform=iOS Simulator,name=iPhone 16'
```

Those tests cover what only works on Apple's platforms: the wake word models on the iOS ONNX Runtime,
Python inside the app, and HTTPS with the bundled certificates.

## Check it on Linux

These need Docker. They cover most of the logic without a Mac.

```bash
scripts/bootstrap.sh         # once, for the wake word models
scripts/test-linux.sh        # AudiopapersKit's tests, with the real Python core and wake word models
scripts/typecheck-linux.sh   # type-checks App/ against stand-ins for Apple's frameworks
```

The type-check catches mistakes in our own code, not misuse of Apple's APIs. When you use a new Apple API
in `App/`, add it to `Tools/AppleStubs`.

## Releasing

```bash
scripts/release.sh 0.2
```

This bumps the version in `project.yml`, commits, tags this repo `v0.2`, tags the `audiopapers` commit
the core comes from `ios-0.2`, and pushes both. Both repos have to be committed and in step with GitHub
first. Then, on a Mac with both repos at those tags, run `xcodegen generate` and archive it in Xcode
(**Product → Archive**).

Settings shows which core commit a build has, for example "Audiopapers 0.2 (core 244d57f)". It says
`-dirty` if the core had uncommitted changes when it was built.

## How it fits together

```
SwiftUI screens and Apple adapters     App/
Logic, tested on Linux                 Sources/AudiopapersKit/
C shim into Python                     Sources/CPythonBridge/
Product logic and Gemini calls         audiopapers_core, from the audiopapers repo
```

- **`App/`:** the screens (`UI/`), the audio engine, speech and ONNX Runtime (`Audio/`), and Keychain,
  notifications, background work and the lock screen (`System/`).
- **`Sources/AudiopapersKit/`:** the reading engine, voice controller, mic pipeline, wake word logic and
  view models. It only uses Foundation and Observation, and reaches Apple's frameworks through protocols
  that `App/` implements.
- **`Tests/AudiopapersKitTests/`:** runs on Linux. **`Tests/AppTests/`:** runs on a simulator.
- **`project.yml`:** the Xcode project's source of truth. The generated project isn't checked in.
- **`.github/workflows/ios.yml`:** runs both kinds of tests. It needs a secret called
  `AUDIOPAPERS_REPO_TOKEN` with read access to the private `audiopapers` repo.

## Changing the core

The core is shared with the Android app, and has to work on Python 3.10 (Android) and 3.13 (iOS) using only
the standard library. When you add a call, add it to
`audiopapers_core/bridge.py` and `Sources/AudiopapersKit/Core.swift`.

## To do

- Build it on a Mac and fix what comes up, then work through the
  [never-run list](DESIGN_DECISIONS.md#12-whats-been-checked-and-what-hasnt) on a real iPhone.
- Tune echo cancellation and "Hey Albert" sensitivity while a paper is reading aloud.
- Check how the Albert, Describe and Skip buttons look on the lock screen.
- Measure how long Kokoro's phonemizer takes on a phone, and move it to Swift if it's slow.
- Move Android onto the shared versions of the code it still has in Kotlin.
- Consider copying the Kokoro files to a public release of your own, so they can't disappear.
