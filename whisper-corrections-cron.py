#!/usr/bin/env python3
"""
Daily Whisper corrections updater.

1. Fetches friendly names for entities exposed to voice assistants in Home Assistant.
2. Reads custom sentence YAML files and sentence-trigger automations so the
   LLM knows what command patterns HA already understands.
3. Reads the last 24h of raw_transcripts.log for HA intent-error rows
   (response_type=error_handling), excluding no_valid_targets which succeed
   on the real satellite device via area context.
4. Asks the local LLM (qwen2.5:1.5b) to classify each transcript as a
   Whisper misrecognition or background noise, using entity names and known
   sentence patterns as context.
5. Appends new [pattern, replacement] pairs to corrections.json.
6. Restarts hailo-whisper via docker compose if the file changed.
"""

import json
import re
import subprocess
import sys
import time
import urllib.request
import yaml  # type: ignore  # installed on Pi, not in local dev env
from datetime import datetime, timezone, timedelta
from pathlib import Path

LOG_FILE             = Path("/home/ctf/homeassistant/whisper-logs/raw_transcripts.log")
CORRECTIONS_FILE     = Path("/home/ctf/homeassistant/whisper-logs/corrections.json")
REVIEW_LOG           = Path("/home/ctf/homeassistant/whisper-logs/corrections_review.log")
ENV_FILE             = Path("/home/ctf/homeassistant/.env")
COMPOSE_FILE         = "/home/ctf/homeassistant/compose.yaml"
CUSTOM_SENTENCES_DIR = Path("/home/ctf/homeassistant/config/custom_sentences/en")
AUTOMATIONS_FILE     = Path("/home/ctf/homeassistant/config/automations.yaml")
OLLAMA_URL           = "http://localhost:11434/v1/chat/completions"
HA_URL               = "http://localhost:8123"
MODEL                = "qwen2.5:1.5b"

def log(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{ts}  {msg}", flush=True)


def retry(fn, attempts=3, delay=5):
    for attempt in range(attempts):
        try:
            return fn()
        except Exception as e:
            if attempt < attempts - 1:
                log(f"  Attempt {attempt + 1}/{attempts} failed: {e} — retrying in {delay}s")
                time.sleep(delay)
            else:
                raise


def load_env():
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


HA_ENTITY_REGISTRY = Path("/home/ctf/homeassistant/config/.storage/core.entity_registry")


def fetch_ha_entities(token):
    """Return friendly names for entities explicitly exposed to voice assistants.

    Reads the entity registry file directly (REST endpoint not available) to
    find entities with options.conversation.should_expose, then resolves their
    friendly names from /api/states.
    """
    with HA_ENTITY_REGISTRY.open() as f:
        data = json.load(f)

    exposed_ids = {
        e["entity_id"]
        for e in data["data"]["entities"]
        if (e.get("options") or {}).get("conversation", {}).get("should_expose")
    }

    if not exposed_ids:
        return []

    req = urllib.request.Request(
        f"{HA_URL}/api/states",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        states = json.loads(resp.read())

    names = set()
    for s in states:
        if s["entity_id"] not in exposed_ids:
            continue
        name = s["attributes"].get("friendly_name", "").strip()
        if name:
            names.add(name)
    return sorted(names)


def _extract_sentences_from_intent_block(data):
    """Recursively pull sentence strings out of a hassil intent data block."""
    sentences = []
    if isinstance(data, list):
        for item in data:
            sentences.extend(_extract_sentences_from_intent_block(item))
    elif isinstance(data, dict):
        for key, value in data.items():
            if key == "sentences":
                if isinstance(value, list):
                    sentences.extend(s for s in value if isinstance(s, str))
                elif isinstance(value, str):
                    sentences.append(value)
            else:
                sentences.extend(_extract_sentences_from_intent_block(value))
    return sentences


def load_custom_sentences():
    """
    Parse custom sentence YAML files and return a flat list of sentence
    pattern strings. Hassil syntax (brackets, pipes, slots) is kept as-is
    so the LLM gets the actual vocabulary range, not just one example.
    """
    patterns = []
    if not CUSTOM_SENTENCES_DIR.exists():
        return patterns
    for path in sorted(CUSTOM_SENTENCES_DIR.glob("*.yaml")):
        try:
            doc = yaml.safe_load(path.read_text())
            intents = doc.get("intents", {}) if isinstance(doc, dict) else {}
            for _, intent_body in intents.items():
                data = intent_body.get("data", []) if isinstance(intent_body, dict) else []
                patterns.extend(_extract_sentences_from_intent_block(data))
        except Exception as e:
            log(f"WARNING: could not parse {path.name}: {e}")
    return patterns


def load_automation_sentences():
    """
    Return sentence strings from conversation-trigger automations
    (trigger: conversation, field: command or sentence).
    """
    sentences = []
    if not AUTOMATIONS_FILE.exists():
        return sentences
    try:
        autos = yaml.safe_load(AUTOMATIONS_FILE.read_text()) or []
        for auto in autos:
            triggers = auto.get("triggers", auto.get("trigger", []))
            if not isinstance(triggers, list):
                triggers = [triggers]
            for t in triggers:
                if not isinstance(t, dict):
                    continue
                if t.get("trigger") != "conversation":
                    continue
                val = t.get("command") or t.get("sentence") or t.get("sentences")
                if isinstance(val, str):
                    sentences.append(val)
                elif isinstance(val, list):
                    sentences.extend(s for s in val if isinstance(s, str))
    except Exception as e:
        log(f"WARNING: could not parse automations.yaml: {e}")
    return sentences


def read_recent_errors(hours=24):
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    errors = []
    if not LOG_FILE.exists():
        return errors
    with LOG_FILE.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            # Support both JSONL (new) and legacy TSV format
            if line.startswith("{"):
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts_str      = rec.get("ts", "")
                raw         = rec.get("raw", "")
                status      = rec.get("response_type", "")
                detail      = rec.get("detail", "")
            else:
                parts = line.split("\t")
                if len(parts) < 5:
                    continue
                ts_str, raw, _, status, detail = (
                    parts[0], parts[1], parts[2], parts[3], parts[4]
                )
            # Candidate for LLM review: HA couldn't match a command intent.
            # "error" = network/parse failure (legacy TSV); "error_handling" = HA intent error.
            # Skip "error" (transient) and non-error responses.
            if status not in ("error", "error_handling"):
                continue
            try:
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
            except ValueError:
                continue
            if ts < cutoff:
                continue
            errors.append({"timestamp": ts_str, "transcript": raw, "error": detail})
    return errors


def call_llm(prompt):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.1,
        "max_tokens": 80,
    }).encode()

    def _call():
        req = urllib.request.Request(
            OLLAMA_URL,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
        return data["choices"][0]["message"]["content"].strip()

    return retry(_call)


def classify_transcript(transcript, entity_names, sentence_patterns):
    """Ask the LLM about a single transcript. Returns (pattern, replacement) or None."""
    entity_list   = ", ".join(entity_names)
    pattern_list  = "\n".join(f"  - {p}" for p in sentence_patterns)

    prompt = (
        "Smart home devices: " + entity_list + "\n\n"
        "Known HA voice command patterns (hassil syntax — brackets = optional, "
        "pipes = alternatives, braces = slots):\n"
        + pattern_list + "\n\n"
        "Task: did the speech-to-text engine mishear a real smart home command?\n"
        "Phonetic misrecognition = a word SOUNDS like the wrong word so the "
        "transcript nearly matches one of the patterns above but fails because "
        "a word was garbled (e.g. 'dying' sounds like 'dining', "
        "'bright under' sounds like 'brighten the').\n\n"
        f'Transcript: "{transcript}"\n\n'
        "Rules:\n"
        "- If it is a phonetic misrecognition of a known command, reply ONLY: "
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

    # Accept YES anywhere — the model is verbose regardless of instructions
    match = re.search(r"YES\s*:\s*(.+?)\s*->\s*(.+)", response, re.IGNORECASE)
    if not match:
        return None

    wrong   = match.group(1).strip().strip('"\'')
    correct = match.group(2).strip().strip('"\'').rstrip(".")

    if not wrong or not correct:
        return None

    # Guard: misheard words must actually appear in the transcript
    if wrong.lower() not in transcript.lower():
        log(f"  Rejecting '{wrong}' -> '{correct}': misheard words not in transcript")
        return None

    # Guard: phrase must be >= 2 words and not the entire transcript
    if (len(wrong.split()) < 2
            or wrong.lower().rstrip(".,!?") == transcript.lower().rstrip(".,!?")):
        log(f"  Rejecting '{wrong}' -> '{correct}': phrase too short or is entire transcript")
        return None

    # Guard: replacement must match a known entity name or action word
    action_words = {"turn on", "turn off", "brighten", "dim", "open", "close",
                    "brighten the", "living room", "dining room", "bedroom",
                    "office", "guest room", "main bedroom"}
    entity_names_lower = [n.lower() for n in entity_names]
    if (not any(correct.lower() in n for n in entity_names_lower)
            and correct.lower() not in action_words):
        log(f"  Rejecting '{wrong}' -> '{correct}': replacement not a known entity or action")
        return None

    # Build word-boundary pattern — escape each word individually
    words   = wrong.split()
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
    env      = load_env()
    ha_token = env.get("HA_ACCESS_TOKEN", "")
    if not ha_token:
        log("ERROR: HA_ACCESS_TOKEN not found in .env — cannot fetch entity list.")
        sys.exit(1)

    log("Fetching HA entity list...")
    try:
        entity_names = retry(lambda: fetch_ha_entities(ha_token))
        log(f"Got {len(entity_names)} entity names.")
    except Exception as e:
        log(f"WARNING: Could not fetch HA entities ({e}), proceeding without them.")
        entity_names = []

    custom   = load_custom_sentences()
    auto_s   = load_automation_sentences()
    sentence_patterns = custom + auto_s
    log(f"Loaded {len(custom)} custom sentence pattern(s) + {len(auto_s)} automation sentence(s).")

    errors = read_recent_errors()
    if not errors:
        log("No errors in last 24h — nothing to do.")
        return

    log(f"Found {len(errors)} error row(s). Classifying each with LLM...")

    existing          = load_corrections()
    existing_patterns = {c[0] for c in existing}
    added, skipped    = [], []

    for e in errors:
        result = classify_transcript(e["transcript"], entity_names, sentence_patterns)
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
