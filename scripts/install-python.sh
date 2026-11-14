#!/usr/bin/env bash
# Xcode build phase: puts Python's standard library and audiopapers_core into the app, before
# signing. Python.xcframework's install_python wraps each binary module as a framework, which is
# the only way iOS will load it. audiopapers_core comes from the sibling audiopapers checkout, or
# AUDIOPAPERS_REPO if that's set.
set -e
core_repo="${AUDIOPAPERS_REPO:-$PROJECT_DIR/../audiopapers}"
if [ ! -d "$core_repo/audiopapers_core" ]; then
    echo "error: audiopapers_core not found in $core_repo. Check out the audiopapers repo beside this one, or set AUDIOPAPERS_REPO." >&2
    exit 1
fi
if [ ! -d "$PROJECT_DIR/Frameworks/Python.xcframework" ]; then
    echo "error: Python.xcframework is missing. Run scripts/bootstrap.sh first." >&2
    exit 1
fi
source "$PROJECT_DIR/Frameworks/Python.xcframework/build/utils.sh"
install_python Frameworks/Python.xcframework

# Most of the standard library's size is its own test suite. None of these are used on a phone.
for unused in test idlelib ensurepip tkinter turtledemo pydoc_data; do
    rm -rf "$CODESIGNING_FOLDER_PATH/python/lib/python3.13/$unused"
done

mkdir -p "$CODESIGNING_FOLDER_PATH/app"
rsync -a --delete --exclude '__pycache__' "$core_repo/audiopapers_core/" "$CODESIGNING_FOLDER_PATH/app/audiopapers_core/"

# Which audiopapers commit the core came from, shown beside the version in Settings, so any
# installed build can be traced back to its core. "-dirty" if the core had uncommitted changes.
core_commit="$(git -C "$core_repo" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$core_repo" status --porcelain -- audiopapers_core 2>/dev/null)" ]; then
    core_commit="$core_commit-dirty"
fi
echo "$core_commit" > "$CODESIGNING_FOLDER_PATH/app/core_commit.txt"
