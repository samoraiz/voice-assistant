# CLAUDE.md — Hailo Voice Assistant

Read this before touching `hailo_ollama_proxy/proxy.py`, the injected system
prompt, or HA intent config.

## Stack

| Service | Container | Role |
|---|---|---|
| `hailo-whisper` | `hailo-whisper` | STT — Whisper on Hailo-10H NPU via Wyoming |
| `hailo-ollama` | `hailo-ollama` | LLM — `qwen2.5:1.5b` on NPU + OpenAI-compat proxy |
| Piper | `piper` | TTS via Wyoming |
| Home Assistant | `homeassistant` | Orchestrator / voice UI |

The proxy in `hailo_ollama_proxy/proxy.py` is the only thing in this repo that
sits on the request path between HA's `Extended OpenAI Conversation`
integration and the native `hailo-ollama` server.

## Detail docs

- [docs/proxy-pipeline.md](docs/proxy-pipeline.md) — proxy layers, repair/reject logic, follow-up handling, known model bugs. Read when changing `proxy.py`.
- [docs/ha-custom-sentences.md](docs/ha-custom-sentences.md) — how to read, edit, and deploy HA custom sentences and intent config.
- [docs/testing-and-deploy.md](docs/testing-and-deploy.md) — live voice testing commands, NPU sharing rules, build/deploy loop.
