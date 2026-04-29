# ============================================================
# Dockerfile — wyoming-hailo-whisper
# Wyoming STT server: Whisper encoder on Hailo NPU, decoder on CPU.
#
# Build (from ~/hailo_apps on the Pi):
#   docker build -t canthefason/wyoming-whisper:latest \
#     --build-arg HAILORT_WHL=hailort-5.3.0-cp311-cp311-linux_aarch64.whl \
#     [--build-arg HEF=whisper_tiny_en_encoder.hef] \
#     .
# ============================================================

FROM python:3.11-slim-bookworm

# ── System runtime deps ──────────────────────────────────────────────────────
# libusb-1.0-0  — required by HailoRT for USB/PCIe device access
#   (compose.yaml also bind-mounts the host libusb, but having it installed
#    keeps ldconfig happy and makes the image self-contained)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/*

# ── HailoRT Python bindings ──────────────────────────────────────────────────
# Must be installed before hailo_platform is imported.
ARG HAILORT_WHL=hailort-5.3.0-cp311-cp311-linux_aarch64.whl
COPY ${HAILORT_WHL} /tmp/hailort.whl
RUN pip install --no-cache-dir /tmp/hailort.whl \
    && rm /tmp/hailort.whl

# ── Python dependencies ──────────────────────────────────────────────────────
# torch     — required by openai-whisper for the CPU decoder
# openai-whisper — mel spectrogram + decoder (encoder runs on NPU)
# wyoming   — Wyoming STT protocol (audio framing, Transcribe/Transcript events)
# numpy     — mel spectrogram preprocessing and NPU buffer I/O
RUN pip install --no-cache-dir \
        torch \
        openai-whisper \
        wyoming \
        numpy

# ── Application code ─────────────────────────────────────────────────────────
COPY wyoming_hailo_whisper/ /app/wyoming_hailo_whisper/
WORKDIR /app

# ── Pre-download Whisper model weights ───────────────────────────────────────
# Bake the tiny.en weights (~75 MB) into the image so the first transcription
# doesn't stall on a network download.
RUN python3 -c "import whisper; whisper.load_model('tiny.en')"

# ── Hailo encoder HEF ────────────────────────────────────────────────────────
# The HEF contains the Whisper encoder compiled for the Hailo-10H NPU.
# It is copied into the image so no host volume mount is needed.
ARG HEF=whisper_tiny_en_encoder.hef
COPY ${HEF} /opt/whisper/encoder.hef

# ── Runtime ──────────────────────────────────────────────────────────────────
EXPOSE 10300

ENTRYPOINT ["python3", "-m", "wyoming_hailo_whisper"]
CMD ["--hef",      "/opt/whisper/encoder.hef", \
     "--uri",      "tcp://0.0.0.0:10300",      \
     "--model",    "tiny.en",                  \
     "--language", "en"]
