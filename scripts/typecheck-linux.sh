#!/usr/bin/env bash
# Type-checks the app's own code on Linux against stand-ins for Apple's frameworks
# (Tools/AppleStubs). Catches mistakes in the app's code; only Xcode can catch misuse of Apple's.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
docker build -q -t audiopapers-swift -f "$here/scripts/linux.Dockerfile" "$here/scripts" >/dev/null
docker run --rm \
    -v "$here":/w/audiopapers-ios \
    -v audiopapers-ios-stubs-build:/w/audiopapers-ios/Tools/AppleStubs/.build \
    -w /w/audiopapers-ios/Tools/AppleStubs \
    audiopapers-swift swift build --target App "$@"
