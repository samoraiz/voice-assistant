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

## Quick Start

1. **Install HailoRT 5.3.0** — download `hailort_5.3.0_*.deb` from [Hailo Developer Hub](https://developer.hailo.ai) and run `sudo dpkg -i hailort_5.3.0_*.deb`.
2. **Check the Python bind-mount path** — run `find /usr -name "_pyhailort*.so" 2>/dev/null`. If it shows a version other than `python3.13`, update the `hailo_platform` paths in `compose.yaml` to match.
3. **Install the model blob** — see `docs/testing-and-deploy.md` for the hailo-ollama model install procedure.
4. **Create your `.env`** — copy `.env.example` to `.env` and set `HA_CONFIG_DIR` to the path of your Home Assistant config directory on the Pi.
5. **Start the stack** — `docker compose up -d`.

## Files

| File / Directory | Purpose |
|---|---|
| `compose.yaml` | 4-service Docker Compose: hailo-ollama, hailo-whisper, piper, homeassistant |
| `.env.example` | Environment variable reference — copy to `.env` and fill in |
| `Dockerfile` | hailo-whisper image (Whisper encoder on Hailo NPU via Wyoming) |
| `hailo_ollama_proxy/` | OpenAI-compat proxy for hailo-ollama; `proxy.py`, `prompts.json`, `entrypoint.sh` |
| `wyoming_hailo_whisper/` | Wyoming STT protocol handler for hailo-whisper |
| `voice-test.sh` | Live smoke test — sends commands through HA and reports spoken replies |
| `whisper-corrections-cron.py` | Updates STT corrections in a running hailo-whisper container |
| `docs/` | Proxy pipeline design, HA custom sentences guide, testing and deploy loop |

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

## Testing voice commands

`voice-test.sh` sends a list of commands through HA's `Extended OpenAI Conversation` agent (the same path the Pi's voice satellite takes after wake word + STT) and prints the spoken reply for each. Useful for live-testing proxy or prompt changes against whatever image is currently deployed on the Pi.

```bash
export HOME_ASSISTANT="<HA long-lived access token>"

bash voice-test.sh                       # default 8-command suite (lights on/off/dim/brighten)
bash voice-test.sh "turn on the lights"  # single ad-hoc command
bash voice-test.sh -f my-commands.txt    # one command per line; blank lines and # comments OK
bash voice-test.sh --log                 # also dump proxy log markers from this run
bash voice-test.sh --interval 30         # seconds between commands (default 45)
```

Each command prints `✔` (speech reply received), `⊘` (silent — proxy blanked a JSON-shaped or rejected reply; the action may or may not have run, use `--log` to see), or `✘` (HA error speech or HTTP/parse failure), plus the wall-clock duration.

| Env var | Default | Purpose |
|---|---|---|
| `HOME_ASSISTANT` | _(required)_ | HA long-lived bearer token |
| `HA_URL` | `http://rpi.local:8123` | Home Assistant base URL |
| `HA_AGENT_ID` | `conversation.extended_openai_conversation` | conversation agent entity_id |
| `PI_SSH` | `hailo-pi` | SSH alias used by `--log` to fetch proxy logs |

## Key Engineering Notes

- `hailo-ollama` is **not** standard Ollama — it has a different API surface, manifest format, and blob storage layout. A translation proxy (baked into the Docker image) bridges it to the OpenAI-compatible API that Home Assistant expects.
- Both `hailo-whisper` and `hailo-ollama` share the same NPU via `HAILO_VDEVICE_GROUP_ID=SHARED`.
- Model blobs must be installed manually — `hailo-ollama pull` does not work. See `02-install-hailo-ollama-npu.sh` for the automated procedure.
- Home Assistant sends invalid JSON (literal newlines in strings) and hailo-ollama re-serialises incorrectly — both fixed by a two-layer sanitisation step in the proxy.
- **Use HA's local NLU for deterministic commands.** Small models like `qwen2.5:1.5b` are non-deterministic — they occasionally hallucinate entity IDs or wrong service calls for common patterns. HA's built-in intent recognition (hassil) runs before the LLM when `prefer_local_intents: true` is set on the pipeline, so commands that match a local sentence pattern are handled instantly and correctly without an LLM round-trip. We cover lights dimming ("dim the office lights to 30%"), shade scene activation ("close the bedroom blinds"), and heat pump source selection ("use the bedroom temperature sensor") with custom sentence YAML files in `config/custom_sentences/en/` and an `intent_script` block in `configuration.yaml` for the custom `HeatPumpSource` intent.

## Related

- Blog post: [How We Reduced LLM Inference Latency by Running Ollama on Hailo AI HAT+2](https://github.com/canthefason/hailo-voice-assistant)
- Hardware: Raspberry Pi 5 8GB + [Hailo AI HAT+2](https://www.raspberrypi.com/products/ai-hat/) + [Waveshare ESP32-S3 AI Smart Speaker](https://www.waveshare.com)

## Status

Work in progress. Still fine-tuning. Alexa is still plugged in.
