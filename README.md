# Hailo Voice Assistant

Fully offline voice assistant running on **Raspberry Pi 5 + Hailo AI HAT+2** (40 TOPS NPU), integrated with Home Assistant.

## Architecture

```
Waveshare ESP32-S3 (wake word + mic)
    → hailo-whisper (STT on NPU)
        → Home Assistant
            → hailo-ollama (LLM on NPU)
                → piper (TTS)
                    → Speaker
```

| Component | Container / Device | Protocol |
|---|---|---|
| Wake Word + Mic | Waveshare ESP32-S3 AI Smart Speaker | ESPHome / Wyoming |
| Speech-to-Text | `hailo-whisper` | Wyoming |
| LLM Inference | `hailo-ollama` | HTTP (proxied) |
| Text-to-Speech | `piper` | Wyoming |
| Orchestration | `homeassistant` | REST / WebSocket |

Everything runs locally. No cloud APIs. No subscriptions.

## Files

| File | Purpose |
|---|---|
| `compose.yaml` | Docker Compose for all services on the Pi |
| `Dockerfile` | Custom hailo-ollama image with translation proxy baked in |
| `esp32.yaml` | ESPHome config for the Waveshare ESP32-S3 AI Smart Speaker |
| `00-setup-ssh.sh` | One-time SSH key setup for Pi access |
| `01-install-hailo-voice-assistant.sh` | Installs base voice assistant stack (Whisper, Piper, HA) |
| `02-install-hailo-ollama-npu.sh` | Installs hailo-ollama with NPU support and proxy |
| `03-upgrade-service.sh` | Upgrades running services in place |
| `pull-compose.sh` | Pulls latest compose file to Pi |
| `wyoming_hailo_whisper/` | Wyoming protocol integration for hailo-whisper |

## Building the hailo-whisper Docker image

The `hailo-whisper` image is built for `linux/arm64` via GitHub Actions (`.github/workflows/build-and-push.yml`) using QEMU cross-compilation on standard `ubuntu-latest` runners.

**One-time setup (GitHub → Settings → Secrets and Variables):**

| Name | Type | Value |
|---|---|---|
| `DOCKERHUB_USERNAME` | Secret | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | Secret | Docker Hub access token (read/write) |
| `WHISPER_VERSION` | Variable | Hailo CDN version for HEF files (e.g. `2.2.0`) |

The encoder HEF is downloaded automatically from the public Hailo CDN — no manual uploads needed.

**The HailoRT wheel is never baked into the image.** `hailo_platform` and its native libraries are bind-mounted from the Pi host at runtime (see `compose.yaml`). This means the Docker image contains no Hailo proprietary binaries and can be published publicly.

## Key Engineering Notes

- `hailo-ollama` is **not** standard Ollama — it has a different API surface, manifest format, and blob storage layout. A translation proxy (baked into the Docker image) bridges it to the OpenAI-compatible API that Home Assistant expects.
- Both `hailo-whisper` and `hailo-ollama` share the same NPU via `HAILO_VDEVICE_GROUP_ID=SHARED`.
- Model blobs must be installed manually — `hailo-ollama pull` does not work. See `02-install-hailo-ollama-npu.sh` for the automated procedure.
- Home Assistant sends invalid JSON (literal newlines in strings) and hailo-ollama re-serialises incorrectly — both fixed by a two-layer sanitisation step in the proxy.

## Related

- Blog post: [How We Reduced LLM Inference Latency by Running Ollama on Hailo AI HAT+2](https://github.com/canthefason/hailo-voice-assistant)
- Hardware: Raspberry Pi 5 8GB + [Hailo AI HAT+2](https://www.raspberrypi.com/products/ai-hat/) + [Waveshare ESP32-S3 AI Smart Speaker](https://www.waveshare.com)

## Status

Work in progress. Still fine-tuning. Alexa is still plugged in.
