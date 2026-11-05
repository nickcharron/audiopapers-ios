#!/usr/bin/env bash
# Fetches what the app needs and isn't checked in, each checked against a known hash: the Python
# runtime for iOS, the wake word's feature models, g2p_en's weights and the CA certificates Python
# uses for HTTPS. Then generates the Xcode project, if XcodeGen is installed. Run it once before
# opening the project. Needs curl, tar and unzip.
set -euo pipefail
cd "$(dirname "$0")/.."

fetch() { # url sha256 output
    local tmp actual
    tmp="$(mktemp)"
    curl -fsSL -o "$tmp" "$1"
    if command -v shasum >/dev/null; then
        actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
    else
        actual="$(sha256sum "$tmp" | cut -d' ' -f1)"
    fi
    if [ "$actual" != "$2" ]; then
        echo "$1 doesn't match its expected SHA-256 (got $actual)" >&2
        rm -f "$tmp"
        exit 1
    fi
    chmod 644 "$tmp"
    mv "$tmp" "$3"
}

mkdir -p Frameworks App/Resources/Fetched
fetched=App/Resources/Fetched

# Python for iOS, from BeeWare's Python-Apple-support: the runtime and standard library.
if [ ! -d Frameworks/Python.xcframework ]; then
    echo "Fetching Python for iOS..."
    work="$(mktemp -d)"
    fetch "https://github.com/beeware/Python-Apple-support/releases/download/3.13-b18/Python-3.13-iOS-support.b18.tar.gz" \
        d06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d "$work/python.tar.gz"
    tar -xzf "$work/python.tar.gz" -C "$work" Python.xcframework
    mv "$work/Python.xcframework" Frameworks/
    rm -rf "$work"
fi

# openWakeWord's two feature models (Apache-2.0), which "Hey Albert" is detected on top of.
wake_root="https://github.com/dscripka/openWakeWord/releases/download/v0.5.1"
[ -f "$fetched/melspectrogram.onnx" ] || fetch "$wake_root/melspectrogram.onnx" \
    ba2b0e0f8b7b875369a2c89cb13360ff53bac436f2895cced9f479fa65eb176f "$fetched/melspectrogram.onnx"
[ -f "$fetched/embedding_model.onnx" ] || fetch "$wake_root/embedding_model.onnx" \
    70d164290c1d095d1d4ee149bc5e00543250a7316b59f31d056cff7bd3075c1f "$fetched/embedding_model.onnx"

# g2p_en's network (Apache-2.0) guesses how words outside Kokoro's word list are said.
if [ ! -f "$fetched/checkpoint20.npz" ]; then
    wheel="$(mktemp)"
    fetch "https://files.pythonhosted.org/packages/d7/d9/b77dc634a7a0c0c97716ba97dd0a28cbfa6267c96f359c4f27ed71cbd284/g2p_en-2.1.0-py3-none-any.whl" \
        2a7aabf1fc7f270fcc3349881407988c9245173c2413debbe5432f4a4f31319f "$wheel"
    unzip -p "$wheel" g2p_en/checkpoint20.npz > "$fetched/checkpoint20.npz"
    rm -f "$wheel"
fi

# Mozilla's CA certificates, from certifi: embedded Python can't reach the system's.
if [ ! -f "$fetched/cacert.pem" ]; then
    wheel="$(mktemp)"
    fetch "https://files.pythonhosted.org/packages/32/d1/a3652fe2c19134d0d15922177821d863cbd7e842d53a21bbe7e8e3a1b5ac/certifi-2026.10.23-py3-none-any.whl" \
        e9b54de76e530bb6cf0ccd036787103acb58fd42ba930ea8bf948ddbaa2f61d1 "$wheel"
    unzip -p "$wheel" certifi/cacert.pem > "$fetched/cacert.pem"
    rm -f "$wheel"
fi

if command -v xcodegen >/dev/null; then
    xcodegen generate
    echo "Ready. Open Audiopapers.xcodeproj."
else
    echo "Fetched everything. To make the Xcode project: brew install xcodegen && xcodegen generate"
fi
