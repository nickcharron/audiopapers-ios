#!/usr/bin/env bash
# Builds and tests AudiopapersKit on Linux with the real Python core, in Docker. Expects the
# audiopapers repo beside this one.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
docker build -q -t audiopapers-swift -f "$here/scripts/linux.Dockerfile" "$here/scripts" >/dev/null
docker run --rm \
    -v "$here":/w/audiopapers-ios \
    -v "$here/../audiopapers":/w/audiopapers:ro \
    -v audiopapers-ios-build:/w/audiopapers-ios/.build \
    -e AUDIOPAPERS_REPO=/w/audiopapers \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -e ORT_PYTHON=/opt/ort/bin/python \
    -w /w/audiopapers-ios \
    audiopapers-swift swift test "$@"
