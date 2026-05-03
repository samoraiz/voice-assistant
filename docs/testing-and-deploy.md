# Testing and deployment

## Live voice testing

Tests run against `rpi.local` with the deployed branch image:

```bash
curl -s -X POST -H "Authorization: Bearer $HOME_ASSISTANT" \
    -H "Content-Type: application/json" \
    -d '{"text":"<command>","agent_id":"conversation.extended_openai_conversation"}' \
    http://rpi.local:8123/api/conversation/process
```

Inspect proxy traffic with:
```bash
ssh hailo-pi 'docker logs hailo-ollama --tail 200'
```

Run `--log-level trace` (default in deployed compose) for full bodies; use
`debug` for system-prompt truncation.

A reliable end-to-end loop takes ~30s between commands (model gen ~10-15s
per turn, two turns per voice command). Tighter than that and HA may
return HTTP 500 from concurrent in-flight requests; this is a test-harness
artefact, not a real regression.

---

## NPU sharing

Both `hailo-whisper` and `hailo-ollama` open `/dev/h1x-0`. They must share
a `HAILO_VDEVICE_GROUP_ID=SHARED` env var or HailoRT refuses concurrent
access. Stop `hailo-whisper` before pulling/installing a new model on
`hailo-ollama` — model download triggers VDevice init and races with the
whisper container.

---

## Build / deploy loop

`.github/workflows/build-and-push.yml` builds `canthefason/hailo-ollama`
on every push to a feature branch. Image tag = `git rev-parse --short HEAD`.
After build:

```bash
# update the tag in the Pi's compose file and bounce the service
ssh hailo-pi "sed -i.bak \
    's|canthefason/hailo-ollama:[a-f0-9]*|canthefason/hailo-ollama:<sha>|' \
    ~/homeassistant/compose.yaml && \
    cd ~/homeassistant && \
    docker compose pull hailo-ollama && \
    docker compose up -d hailo-ollama"
```
