#!/usr/bin/env python3
"""
Daily Whisper corrections updater.

1. Fetches all voice-relevant entity friendly names from Home Assistant.
2. Reads the last 24h of raw_transcripts.log for error rows.
3. Asks the local LLM (qwen2.5:1.5b) to classify each transcript as a
   Whisper misrecognition or background noise, using the entity list as context.
4. Appends new [pattern, replacement] pairs to corrections.json.
5. Restarts hailo-whisper via docker compose if the file changed.
"""

import json
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

LOG_FILE         = Path("/home/ctf/homeassistant/whisper-logs/raw_transcripts.log")
CORRECTIONS_FILE = Path("/home/ctf/homeassistant/whisper-logs/corrections.json")
REVIEW_LOG       = Path("/home/ctf/homeassistant/whisper-logs/corrections_review.log")
ENV_FILE         = Path("/home/ctf/homeassistant/.env")
COMPOSE_FILE     = "/home/ctf/homeassistant/compose.yaml"
OLLAMA_URL       = "http://localhost:11434/v1/chat/completions"
HA_URL           = "http://localhost:8123"
MODEL            = "qwen2.5:1.5b"

HA_VOICE_DOMAINS = {"light", "switch", "scene", "cover", "fan", "climate",
                    "media_player", "input_boolean", "script", "automation"}


def log(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{ts}  {msg}", flush=True)


def load_env():
    """Parse key=value pairs from the .env file."""
    env = {}
    if not ENV_FILE.exists():
        return env
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip()
    return env


def fetch_ha_entities(token):
    """Return a sorted list of friendly names for voice-relevant HA entities."""
    req = urllib.request.Request(
        f"{HA_URL}/api/states",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        states = json.loads(resp.read())

    names = set()
    for s in states:
        domain = s["entity_id"].split(".")[0]
        if domain not in HA_VOICE_DOMAINS:
            continue
        name = s["attributes"].get("friendly_name", "").strip()
        if name:
            names.add(name)

    return sorted(names)


def read_recent_errors(hours=24):
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    errors = []
    if not LOG_FILE.exists():
        return errors
    with LOG_FILE.open() as f:
        for line in f:
            parts = line.strip().split("\t")
            if len(parts) < 5:
                continue
            ts_str, raw, _, status, result = (
                parts[0], parts[1], parts[2], parts[3], parts[4]
            )
            if status != "error":
                continue
            try:
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            except ValueError:
                continue
            if ts < cutoff:
                continue
            errors.append({"timestamp": ts_str, "transcript": raw, "error": result})
    return errors


def call_llm(prompt):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.1,
        "max_tokens": 80,
    }).encode()
    req = urllib.request.Request(
        OLLAMA_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]["content"].strip()


def classify_transcript(transcript, entity_names):
    """Ask the LLM about a single transcript. Returns (pattern, replacement) or None."""
    entity_list = ", ".join(entity_names)
    prompt = (
        "Smart home devices: " + entity_list + "\n\n"
        "Task: did the speech-to-text engine mishear a real smart home command?\n"
        "Phonetic misrecognition = a word SOUNDS like the wrong word "
        "(e.g. 'dying' sounds like 'dining', 'bright under' sounds like 'brighten the').\n\n"
        f'Transcript: "{transcript}"\n\n'
        "Rules:\n"
        "- If it is a phonetic misrecognition of a home command, reply ONLY: "
        "YES: <misheard words> -> <correct words>\n"
        "- Otherwise reply ONLY: NO\n"
        "- Do not write anything else.\n\n"
        "Examples:\n"
        '"Turn off the dying room lights." -> YES: dying room -> dining room\n'
        '"I have the permissions" -> NO\n'
        '"bright under office lights." -> YES: bright under -> brighten the\n\n'
        f'"{transcript}" ->'
    )
    response = call_llm(prompt)
    log(f"  [{transcript[:50]}] -> {response[:80]}")

    # Accept YES anywhere in the response — the model is verbose regardless of instructions
    match = re.search(r"YES\s*:\s*(.+?)\s*->\s*(.+)", response, re.IGNORECASE)
    if not match:
        return None

    wrong = match.group(1).strip().strip('"').strip("'")
    correct = match.group(2).strip().strip('"').strip("'").rstrip(".")

    if not wrong or not correct:
        return None

    # Guard: misheard words must actually appear in the transcript
    if wrong.lower() not in transcript.lower():
        log(f"  Rejecting '{wrong}' -> '{correct}': misheard words not in transcript")
        return None

    # Guard: misheard phrase must be >= 2 words and not the entire transcript
    # (single-word or whole-transcript matches are too ambiguous to correct safely)
    if len(wrong.split()) < 2 or wrong.lower().rstrip(".,!?") == transcript.lower().rstrip(".,!?"):
        log(f"  Rejecting '{wrong}' -> '{correct}': phrase too short or is entire transcript")
        return None

    # Guard: replacement must loosely match a known entity name or action word
    action_words = {"turn on", "turn off", "brighten", "dim", "open", "close",
                    "brighten the", "living room", "dining room", "bedroom",
                    "office", "guest room", "main bedroom"}
    entity_names_lower = [n.lower() for n in entity_names]
    replacement_lower = correct.lower()
    if (not any(replacement_lower in name for name in entity_names_lower)
            and replacement_lower not in action_words):
        log(f"  Rejecting '{wrong}' -> '{correct}': replacement not in entity list or action words")
        return None

    # Build a word-boundary pattern — escape each word individually to avoid
    # re.escape adding backslashes before spaces
    words = wrong.split()
    pattern = r"\b" + r"\s+".join(re.escape(w) for w in words) + r"\b"
    return pattern, correct


def load_corrections():
    if not CORRECTIONS_FILE.exists():
        return []
    with CORRECTIONS_FILE.open() as f:
        return json.load(f)


def save_corrections(corrections):
    with CORRECTIONS_FILE.open("w") as f:
        json.dump(corrections, f, indent=2)
        f.write("\n")


def restart_hailo_whisper():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE, "up", "-d", "--no-deps", "hailo-whisper"],
        check=True,
        capture_output=True,
    )


def main():
    env = load_env()
    ha_token = env.get("HA_ACCESS_TOKEN", "")
    if not ha_token:
        log("ERROR: HA_ACCESS_TOKEN not found in .env — cannot fetch entity list.")
        sys.exit(1)

    log("Fetching HA entity list...")
    try:
        entity_names = fetch_ha_entities(ha_token)
        log(f"Got {len(entity_names)} entity names.")
    except Exception as e:
        log(f"WARNING: Could not fetch HA entities ({e}), proceeding without them.")
        entity_names = []

    errors = read_recent_errors()
    if not errors:
        log("No errors in last 24h — nothing to do.")
        return

    log(f"Found {len(errors)} error row(s). Classifying each with LLM...")

    existing = load_corrections()
    existing_patterns = {c[0] for c in existing}

    added = []
    skipped = []
    for e in errors:
        result = classify_transcript(e["transcript"], entity_names)
        if result is None:
            continue
        pattern, replacement = result
        try:
            re.compile(pattern, re.IGNORECASE)
        except re.error as err:
            log(f"Skipping bad pattern {pattern!r}: {err}")
            skipped.append(pattern)
            continue
        if pattern in existing_patterns:
            log(f"Pattern already exists, skipping: {pattern!r}")
            continue
        existing.append([pattern, replacement])
        existing_patterns.add(pattern)
        added.append((pattern, replacement))

    with REVIEW_LOG.open("a") as f:
        f.write(
            f"{datetime.now(timezone.utc).isoformat()}\t"
            f"errors={len(errors)}\t"
            f"added={added}\t"
            f"skipped={skipped}\n"
        )

    if added:
        save_corrections(existing)
        log(f"Added {len(added)} correction(s): {added}")
        restart_hailo_whisper()
        log("hailo-whisper restarted.")
    else:
        log("No new corrections to add.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"FATAL: {e}")
        sys.exit(1)
