# Swift on Linux, with the Python headers the bridge compiles against. Apple's frameworks aren't
# here, so this tests AudiopapersKit and type-checks the app against stand-ins (Tools/AppleStubs).
FROM swift:6.2-jammy
RUN apt-get update && apt-get install -y --no-install-recommends libpython3.10-dev python3.10 python3.10-venv && rm -rf /var/lib/apt/lists/*
# Runs the wake word's real models for RealWakeModelTests. A separate environment, so the core's
# own tests can't come to lean on numpy, which the phone doesn't have.
RUN python3.10 -m venv /opt/ort && /opt/ort/bin/pip install --no-cache-dir onnxruntime==1.23.2 numpy
