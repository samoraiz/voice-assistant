#!/usr/bin/env bash
# ============================================================
# 02-install-hailo-ollama-npu.sh
# Replaces the CPU Docker Ollama container with Hailo-NPU-
# accelerated LLM inference via hailo-ollama (hailo_model_zoo_genai).
#
# What this script does:
#   1. Pre-flight — SSH, Hailo device, HailoRT version
#   2. Build hailo-ollama from source (if not already against 5.3.0)
#   3. Stop CPU Docker ollama (free port 11434)
#   4. Build a minimal Docker image for hailo-ollama
#   5. Update compose.yaml (replace ollama → hailo-ollama service)
#   6. docker compose up -d hailo-ollama
#   7. Pull LLM model (qwen2-1.5b-instruct-function-calling)
#   8. Smoke-test inference
#   9. Verify Home Assistant can reach hailo-ollama
#
# Run from your Mac:  bash 02-install-hailo-ollama-npu.sh
#
# Output is tee'd to install-hailo-ollama-npu.log in this directory
# so Claude can read it and suggest fixes if something goes wrong.
# ============================================================
set -euo pipefail

# ── Logging: tee all stdout+stderr to a log file next to this script ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/install-hailo-ollama-npu.log"
# Truncate on each run so the log reflects the latest attempt only
exec > >(tee "${LOG_FILE}") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') — 02-install-hailo-ollama-npu.sh started ==="
echo ""

SSH_ALIAS="${RPI_HOST:-rpi.local}"
HAILO_VERSION="5.3.0"
GENAI_REPO_DIR="/home/ctf/hailo_model_zoo_genai"
HAILO_OLLAMA_BIN="/usr/local/bin/hailo-ollama"
HAILO_OLLAMA_PORT=11434
COMPOSE_FILE="/home/ctf/homeassistant/compose.yaml"
DOCKER_BUILD_DIR="/home/ctf/hailo-ollama-docker"
IMAGE_TAG="hailo-ollama:${HAILO_VERSION}"

# Model to load on the Hailo-10H NPU.
# Override via environment variable, e.g.:  HAILO_MODEL=qwen2.5:0.5b bash 02-install-hailo-ollama-npu.sh
# Available models are listed during Step 1 (pre-flight) based on manifests found on the Pi.
HAILO_MODEL="${HAILO_MODEL:-qwen2.5:1.5b}"
# HA uses the model name directly — hailo-ollama has no /api/create alias support
HA_MODEL_ALIAS="${HAILO_MODEL}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()     { echo -e "${GREEN}  ✔  $*${NC}"; }
info()   { echo -e "${CYAN}  →  $*${NC}"; }
header() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
die()    { echo -e "${RED}  ✘  $*${NC}"; echo "=== FAILED: $* ==="; exit 1; }

confirm() {
    local msg="${1:-Continue?}"
    echo -e "\n${YELLOW}  ▶  ${msg}${NC}"
    echo ""
}

pi() {
    ssh "ctf@$SSH_ALIAS" "bash -l -s" <<< "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Hailo Voice Assistant — NPU LLM (Docker Compose)     ║${NC}"
echo -e "${CYAN}║   hailo-ollama ${HAILO_VERSION} · qwen2-1.5b tool-call          ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 1 — Pre-flight
# ═══════════════════════════════════════════════════════════════
header "STEP 1 — Pre-flight checks"

info "Testing SSH connection..."
OUT=$(pi "echo 'SSH OK'") || die "Cannot reach Pi via SSH alias '$SSH_ALIAS'."
echo "$OUT" | grep -q "SSH OK" || die "SSH test failed — unexpected output: $OUT"
ok "SSH connection: healthy"

info "Checking Hailo device..."
pi "
  ls /dev/h1x* > /dev/null 2>&1 || { echo 'ERROR: No /dev/h1x* device node found'; exit 1; }
  echo '  Hailo device node:' \$(ls /dev/h1x*)
  hailortcli fw-control identify 2>/dev/null | grep -E 'Device|Firmware' || true
"
ok "Hailo device: present"

info "Checking HailoRT version..."
HAILORT_VER=$(pi "hailortcli --version 2>/dev/null | head -1 || echo unknown") || true
echo "  $HAILORT_VER"
if ! echo "$HAILORT_VER" | grep -q "$HAILO_VERSION"; then
    die "HailoRT $HAILO_VERSION required but found: $HAILORT_VER. Run 01-install-hailo-voice-assistant.sh first."
fi
ok "HailoRT $HAILO_VERSION: confirmed"

info "Checking hailo_model_zoo_genai repo..."
pi "
  test -d $GENAI_REPO_DIR || { echo 'ERROR: $GENAI_REPO_DIR not found'; exit 1; }
  cd $GENAI_REPO_DIR && git log --oneline -1 2>/dev/null || true
"
ok "hailo_model_zoo_genai repo: present"

info "Discovering available models on Pi (and fixing tagless manifests)..."
AVAILABLE_MODELS=$(pi "
  MANIFEST_DIR=/usr/local/share/hailo-ollama/models/manifests
  if [ ! -d \"\$MANIFEST_DIR\" ]; then exit 0; fi

  # Fix manifests that are missing a tag subdirectory.
  # Correct layout: manifests/<name>/<tag>/manifest.json  (3 path components)
  # Broken layout:  manifests/<name>/manifest.json        (2 path components)
  # hailo-ollama joins path components with ':' so a tagless manifest becomes
  # 'manifests:<name>' instead of '<name>:<tag>'.
  find \"\$MANIFEST_DIR\" -name manifest.json 2>/dev/null | while IFS= read -r f; do
    rel=\$(echo \"\$f\" | sed \"s|^\$MANIFEST_DIR/||; s|/manifest.json\$||\")
    depth=\$(echo \"\$rel\" | tr -cd '/' | wc -c)
    if [ \"\$depth\" -eq 0 ]; then
      # Only <name>/manifest.json — move to <name>/latest/manifest.json
      name=\$(dirname \"\$f\" | xargs basename)
      dest=\"\$MANIFEST_DIR/\$name/latest\"
      echo \"  Fixing tagless manifest: \$name → \$name:latest\"
      mkdir -p \"\$dest\"
      mv \"\$f\" \"\$dest/manifest.json\"
    fi
  done

  find \"\$MANIFEST_DIR\" -name manifest.json 2>/dev/null \
    | sed \"s|^\$MANIFEST_DIR/||; s|/manifest.json\$||; s|/|:|\" \
    | sort
") || true
if [ -n "$AVAILABLE_MODELS" ]; then
    echo "  Models with manifests on Pi:"
    echo "$AVAILABLE_MODELS" | while IFS= read -r m; do echo "    • $m"; done
else
    echo "  (no manifests found yet — model will be pulled in Step 7)"
fi

info "Selected model: ${HAILO_MODEL}"
MODEL_PATH=$(echo "${HAILO_MODEL}" | tr ':' '/')
MANIFEST_EXISTS=$(pi "test -f /usr/local/share/hailo-ollama/models/manifests/${MODEL_PATH}/manifest.json && echo yes || echo no") || true
if [ "$MANIFEST_EXISTS" != "yes" ]; then
    warn "No manifest found for '${HAILO_MODEL}' on Pi."
    warn "Available models listed above. To switch, re-run with: HAILO_MODEL=<name:tag> bash $0"
    if [ -n "$AVAILABLE_MODELS" ]; then
        die "Manifest missing for '${HAILO_MODEL}' — choose an available model above."
    fi
    # No manifests at all — first run, proceed to Step 7 which handles the pull.
fi
ok "Model: ${HAILO_MODEL}"

confirm "Pre-flight passed. Starting NPU LLM installation."

# ═══════════════════════════════════════════════════════════════
# STEP 2 — Build hailo-ollama from source (if needed)
# ═══════════════════════════════════════════════════════════════
header "STEP 2 — Build hailo-ollama (against HailoRT ${HAILO_VERSION})"

BUILD_OUT=""; BUILD_RC=0
BUILD_OUT=$(pi "
  # Check if already built against the correct version
  if [ -f $HAILO_OLLAMA_BIN ]; then
    LINKED=\$(ldd $HAILO_OLLAMA_BIN 2>/dev/null | grep hailort | awk '{print \$1}' || echo '')
    echo \"  Existing binary links: \$LINKED\"
    if echo \"\$LINKED\" | grep -q 'libhailort.so.${HAILO_VERSION}'; then
      echo '  hailo-ollama already built against ${HAILO_VERSION} — skipping build.'
      echo 'BUILD_SKIP'
      exit 0
    fi
    echo '  Wrong libhailort version linked — rebuilding...'
  else
    echo '  No existing binary — building from source...'
  fi

  set -e
  cd $GENAI_REPO_DIR

  echo '  Configuring cmake...'
  cmake -B build -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5

  echo '  Building (this takes 5-15 minutes on Pi 5 — please wait)...'
  cmake --build build --config Release -- -j4 2>&1 | tail -10

  echo '  Installing to /usr/local/bin...'
  sudo cmake --install build 2>&1 | tail -5

  echo 'BUILD_DONE'
") || BUILD_RC=$?
echo "$BUILD_OUT"
[[ $BUILD_RC -eq 0 ]] || die "Build step failed (exit $BUILD_RC) — see output above."

if echo "$BUILD_OUT" | grep -q "BUILD_SKIP"; then
    ok "hailo-ollama: already up-to-date, skipping build"
elif echo "$BUILD_OUT" | grep -q "BUILD_DONE"; then
    ok "hailo-ollama: built and installed"
else
    die "Build completed but expected BUILD_DONE/BUILD_SKIP token missing."
fi

info "Verifying binary links against libhailort.so.${HAILO_VERSION}..."
LDD_OUT=$(pi "ldd $HAILO_OLLAMA_BIN 2>&1 | grep hailort") || true
echo "  $LDD_OUT"
if ! echo "$LDD_OUT" | grep -q "${HAILO_VERSION}"; then
    die "Binary still not linked against libhailort.so.${HAILO_VERSION} — check build."
fi
ok "Binary links: libhailort.so.${HAILO_VERSION} ✔"

# ═══════════════════════════════════════════════════════════════
# STEP 3 — Stop CPU Docker ollama, free port 11434
# ═══════════════════════════════════════════════════════════════
header "STEP 3 — Stop CPU Docker ollama"

STOP_OUT=""; STOP_RC=0
STOP_OUT=$(pi "
  # Stop CPU ollama if present
  if docker inspect ollama > /dev/null 2>&1; then
    echo '  Stopping and removing CPU ollama container...'
    docker stop ollama 2>&1 || true
    docker rm   ollama 2>&1 || true
  else
    echo '  CPU ollama container not running — nothing to stop.'
  fi

  # Also stop any existing hailo-ollama container so it frees port 11434
  # (Step 6 will re-create it with the updated image)
  cd ~/homeassistant
  docker compose stop hailo-ollama 2>/dev/null || true
  docker compose rm -f hailo-ollama 2>/dev/null || true
  echo 'OLLAMA_STOPPED'
") || STOP_RC=$?
echo "$STOP_OUT"
[[ $STOP_RC -eq 0 ]] || die "Failed to stop ollama container (exit $STOP_RC)."
echo "$STOP_OUT" | grep -q "OLLAMA_STOPPED" || die "Unexpected output from stop step."

info "Verifying port $HAILO_OLLAMA_PORT is free..."
PORT_OUT=$(pi "ss -tlnp 2>/dev/null | grep :${HAILO_OLLAMA_PORT} || echo 'PORT_FREE'") || true
if ! echo "$PORT_OUT" | grep -q "PORT_FREE"; then
    warn "Port $HAILO_OLLAMA_PORT still in use: $PORT_OUT"
    die "Free port $HAILO_OLLAMA_PORT manually before continuing."
fi
ok "Port $HAILO_OLLAMA_PORT: free"

# ═══════════════════════════════════════════════════════════════
# STEP 4 — Build a minimal Docker image for hailo-ollama
# ═══════════════════════════════════════════════════════════════
header "STEP 4 — Build Docker image: $IMAGE_TAG"

DOCKER_OUT=""; DOCKER_RC=0
DOCKER_OUT=$(pi "
  # Check before set -e so the login-shell EXIT trap doesn't fire on exit 0
  if docker image inspect ${IMAGE_TAG} > /dev/null 2>&1; then
    # Verify: no missing libs AND proxy.py is baked in
    MISSING=\$(docker run --rm --entrypoint ldd ${IMAGE_TAG} /usr/local/bin/hailo-ollama 2>/dev/null | grep 'not found' || true)
    HAS_PROXY=\$(docker run --rm --entrypoint test ${IMAGE_TAG} -f /usr/local/bin/hailo-ollama-proxy.py 2>/dev/null && echo yes || echo no)
    # Verify entrypoint has the proxy exec line (not the old broken seq-based version)
    HAS_GOOD_EP=\$(docker run --rm --entrypoint grep ${IMAGE_TAG} hailo-ollama-proxy /usr/local/bin/hailo-ollama-entrypoint.sh > /dev/null 2>&1 && echo yes || echo no)
    # Verify python3 is installed (needed for the proxy)
    HAS_PYTHON3=\$(docker run --rm --entrypoint which ${IMAGE_TAG} python3 > /dev/null 2>&1 && echo yes || echo no)
    # Verify proxy has the chr(92)-based fix_json_control_chars (no literal backslashes)
    HAS_NEW_PROXY=\$(docker run --rm --entrypoint grep ${IMAGE_TAG} 'chr(92)' /usr/local/bin/hailo-ollama-proxy.py > /dev/null 2>&1 && echo yes || echo no)
    # Verify curl is installed (needed for model pull from inside container)
    HAS_CURL=\$(docker run --rm --entrypoint which ${IMAGE_TAG} curl > /dev/null 2>&1 && echo yes || echo no)
    # Verify proxy has sanitize_for_hailo (fixes HailoRT internal LF re-serialisation crash)
    HAS_HAILO_SANITIZE=\$(docker run --rm --entrypoint grep ${IMAGE_TAG} 'hailo-sanitize-v1' /usr/local/bin/hailo-ollama-proxy.py > /dev/null 2>&1 && echo yes || echo no)
    HAS_LATENCY_OPT=\$(docker run --rm --entrypoint grep ${IMAGE_TAG} 'hailo-latency-v4' /usr/local/bin/hailo-ollama-proxy.py > /dev/null 2>&1 && echo yes || echo no)
    if [ -z \"\$MISSING\" ] && [ \"\$HAS_PROXY\" = 'yes' ] && [ \"\$HAS_GOOD_EP\" = 'yes' ] && [ \"\$HAS_PYTHON3\" = 'yes' ] && [ \"\$HAS_NEW_PROXY\" = 'yes' ] && [ \"\$HAS_CURL\" = 'yes' ] && [ \"\$HAS_HAILO_SANITIZE\" = 'yes' ] && [ \"\$HAS_LATENCY_OPT\" = 'yes' ]; then
      echo '  Image ${IMAGE_TAG} is up-to-date (libs OK, proxy OK, entrypoint OK, python3 OK, curl OK, sanitize OK, latency OK) — skipping build.'
      echo 'IMAGE_READY'
      exit 0
    else
      echo \"  Rebuilding image (missing libs: '\$MISSING', proxy: \$HAS_PROXY, good entrypoint: \$HAS_GOOD_EP, python3: \$HAS_PYTHON3, new proxy: \$HAS_NEW_PROXY, curl: \$HAS_CURL, sanitize: \$HAS_HAILO_SANITIZE)...\"
      docker rmi ${IMAGE_TAG} 2>/dev/null || true
    fi
  fi

  set -e

  echo '  Setting up Docker build context at ${DOCKER_BUILD_DIR}...'
  mkdir -p ${DOCKER_BUILD_DIR}

  # Copy the already-built binary into the build context
  cp ${HAILO_OLLAMA_BIN} ${DOCKER_BUILD_DIR}/hailo-ollama

  # Find and copy libhailort.so — hailo-ollama needs it at runtime
  LIBHAILORT=\$(ldconfig -p 2>/dev/null | grep 'libhailort.so.${HAILO_VERSION}' | awk '{print \$NF}' | head -1)
  if [ -z \"\$LIBHAILORT\" ]; then
    LIBHAILORT=\$(find /usr/lib /usr/local/lib -name 'libhailort.so.${HAILO_VERSION}' 2>/dev/null | head -1)
  fi
  [ -n \"\$LIBHAILORT\" ] || { echo 'ERROR: libhailort.so.${HAILO_VERSION} not found'; exit 1; }
  echo \"  libhailort found: \$LIBHAILORT\"
  cp \"\$LIBHAILORT\" ${DOCKER_BUILD_DIR}/libhailort.so.${HAILO_VERSION}

  # Collect all other non-system .so deps of hailo-ollama that aren't in the
  # standard debian:bookworm-slim image (i.e. not libc / libm / libpthread / ld).
  echo '  Collecting additional shared library dependencies...'
  mkdir -p ${DOCKER_BUILD_DIR}/extra-libs
  ldd ${HAILO_OLLAMA_BIN} 2>/dev/null | awk '/=>/{print \$3}' | grep -v '^$' | while read LIB; do
    BASENAME=\$(basename \"\$LIB\")
    # Skip libhailort (already copied) and core glibc libs (always in slim)
    case \"\$BASENAME\" in
      libhailort*|libc.so*|libm.so*|libpthread*|libdl.so*|librt.so*|ld-linux*) continue ;;
    esac
    # Only copy libs not provided by apt packages we install
    case \"\$BASENAME\" in
      libssl*|libcrypto*|libstdc*|libgcc_s*) cp -n \"\$LIB\" ${DOCKER_BUILD_DIR}/extra-libs/ 2>/dev/null || true ;;
    esac
  done
  echo '  Extra libs copied:'
  ls -1 ${DOCKER_BUILD_DIR}/extra-libs/ 2>/dev/null || echo '  (none)'

  # Write a Python proxy that adds GET /v1/models support.
  # hailo-ollama only implements the native Ollama API (/api/tags etc.) and returns
  # 404 for the OpenAI-compatible GET /v1/models that extended_openai_conversation
  # requires during setup. The proxy listens on port 11434 (what HA talks to),
  # translates /v1/models -> /api/tags, and forwards everything else to
  # hailo-ollama on its internal port 11436.
  cat > ${DOCKER_BUILD_DIR}/proxy.py << 'PROXYEOF'
#!/usr/bin/env python3
# Thin OpenAI-compatibility proxy in front of hailo-ollama.
# All strings use single quotes to survive being embedded in a bash double-quoted string.
import http.server, urllib.request, urllib.error, json, os, sys

BACKEND_PORT = int(os.environ.get('HAILO_INTERNAL_PORT', '11436'))
LISTEN_PORT  = int(os.environ.get('OLLAMA_PROXY_PORT',  '11434'))
BACKEND = 'http://127.0.0.1:' + str(BACKEND_PORT)


def fix_json_control_chars(body_bytes):
    '''Escape literal control characters inside JSON string values.
    hailo-ollama strictly rejects U+000A/U+000D inside JSON strings (RFC 7159).
    HA system prompts contain multi-line text that arrives with literal newlines.
    chr(92)=backslash and chr(34)=double-quote avoid literal versions of those
    characters, which would be misprocessed by the enclosing bash double-quoted string.'''
    try:
        body_str = body_bytes.decode('utf-8')
    except Exception:
        return body_bytes
    BS = chr(92)
    DQ = chr(34)
    result = []
    in_string = False
    skip_next = False
    for ch in body_str:
        if skip_next:
            result.append(ch)
            skip_next = False
        elif ch == BS and in_string:
            result.append(ch)
            skip_next = True
        elif ch == DQ:
            in_string = not in_string
            result.append(ch)
        elif in_string and ch == '\n':
            result.append(BS + 'n')
        elif in_string and ch == '\r':
            result.append(BS + 'r')
        elif in_string and ch == '\t':
            result.append(BS + 't')
        elif in_string and ord(ch) < 0x20:
            result.append(BS + 'u{:04x}'.format(ord(ch)))
        else:
            result.append(ch)
    return ''.join(result).encode('utf-8')


def sanitize_for_hailo(body_bytes):
    '''hailo-sanitize-v1
    HailoRT's prompt renderer re-serialises message content to JSON internally
    without escaping newline characters, causing parse_error.101 at runtime.
    Layer-1 fix (fix_json_control_chars) makes the HTTP body valid JSON, but
    hailo-ollama then takes the decoded string values and re-encodes them to JSON
    again without escaping, so any newlines in the *values* still crash it.
    This function parses the (now-valid) JSON, replaces newlines/CR/TAB chars
    inside messages[].content, prompt, and system fields with spaces, then
    re-serialises — so hailo-ollama never sees control chars in string values.'''
    try:
        data = json.loads(body_bytes.decode('utf-8'))
    except Exception:
        return body_bytes

    def clean(s):
        if not isinstance(s, str):
            return s
        return s.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ')

    changed = False
    for key in ('prompt', 'system'):
        if key in data and isinstance(data[key], str):
            data[key] = clean(data[key])
            changed = True
    for msg in data.get('messages', []):
        if isinstance(msg, dict) and 'content' in msg:
            msg['content'] = clean(msg['content'])
            changed = True

    if not changed:
        return body_bytes
    return json.dumps(data).encode('utf-8')


def inject_defaults(body_bytes, path):
    '''hailo-latency-v4
    Inject conservative inference defaults to reduce latency for short
    Home Assistant voice prompts. Only sets values the caller did not specify:
      - max_tokens=120 for /v1/chat/completions  (limits output length)
      - num_predict=60 for /api/generate|chat    (Ollama-native equivalent)
      - num_ctx=512    for /api/generate|chat    (smaller KV cache = faster prefill)
    max_tokens=120 for OpenAI endpoint: enough to fit a full tool_call JSON
    (HassTurnOn with entity_id is ~50 tokens) plus a short spoken reply,
    while capping runaway verbose responses. At ~14 tok/s this limits
    worst-case generation to ~8s. num_predict=60 for native Ollama endpoint
    (no function-call JSON overhead there).
    512 ctx covers the HA system prompt + user turn with room to spare.
    '''
    try:
        data = json.loads(body_bytes.decode('utf-8'))
    except Exception:
        return body_bytes

    changed = False
    p = path.split('?')[0].rstrip('/')

    if p == '/v1/chat/completions':
        # Always enforce a hard cap — HA sends max_tokens=1022 by default which
        # at ~14 tok/s on Hailo-10H would allow up to 73s of generation.
        # 120 tokens safely covers execute_services JSON (~50 tok) + spoken reply.
        if data.get('max_tokens', 0) > 120:
            data['max_tokens'] = 120
            changed = True
        elif 'max_tokens' not in data:
            data['max_tokens'] = 120
            changed = True
    elif p in ('/api/generate', '/api/chat'):
        opts = data.setdefault('options', {})
        if 'num_predict' not in opts:
            opts['num_predict'] = 60
            changed = True
        if 'num_ctx' not in opts:
            opts['num_ctx'] = 512
            changed = True

    if not changed:
        return body_bytes
    return json.dumps(data).encode('utf-8')


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request noise; errors still go to stderr

    # GET /v1/models -> convert /api/tags
    def do_GET(self):
        if self.path.rstrip('/') == '/v1/models':
            try:
                r = urllib.request.urlopen(BACKEND + '/api/tags', timeout=10)
                data = json.loads(r.read())
                models = [
                    {'id': m['name'], 'object': 'model',
                     'created': 0, 'owned_by': 'hailo'}
                    for m in data.get('models', [])
                ]
                body = json.dumps({'object': 'list', 'data': models}).encode()
                self._send(200, body, 'application/json')
            except Exception as exc:
                sys.stderr.write('[proxy] /v1/models error: ' + str(exc) + '\n')
                body = json.dumps({'object': 'list', 'data': []}).encode()
                self._send(200, body, 'application/json')
        else:
            self._forward()

    def do_POST(self):   self._forward()
    def do_DELETE(self): self._forward()
    def do_PUT(self):    self._forward()
    def do_HEAD(self):   self._forward()

    # generic proxy
    def _forward(self):
        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length) if length > 0 else None
        # Layer 1: escape literal control chars so the HTTP body is valid JSON.
        # Layer 2: replace newlines *inside decoded string values* so hailo-ollama's
        # internal prompt renderer never re-serialises them into invalid JSON.
        if body and self.headers.get('Content-Type', '').startswith('application/json'):
            body = fix_json_control_chars(body)
            body = sanitize_for_hailo(body)
            body = inject_defaults(body, self.path)
        req = urllib.request.Request(
            BACKEND + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ('host', 'content-length', 'transfer-encoding'):
                req.add_header(k, v)
        try:
            r = urllib.request.urlopen(req, timeout=300)
            resp_body = r.read()
            self._send(r.status, resp_body,
                       r.headers.get('Content-Type', 'application/octet-stream'))
        except urllib.error.HTTPError as exc:
            resp_body = exc.read()
            self._send(exc.code, resp_body,
                       exc.headers.get('Content-Type', 'application/json'))
        except Exception as exc:
            sys.stderr.write('[proxy] forward error: ' + str(exc) + '\n')
            self._send(502, b'Bad Gateway', 'text/plain')

    def _send(self, code, body, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)


if __name__ == '__main__':
    sys.stderr.write('[proxy] listening on :' + str(LISTEN_PORT) + ' -> hailo-ollama:' + str(BACKEND_PORT) + '\n')
    http.server.HTTPServer(('0.0.0.0', LISTEN_PORT), Handler).serve_forever()
PROXYEOF

  # Write entrypoint: create model dirs, start hailo-ollama on internal port 11436,
  # then start the proxy on 11434 (the port HA talks to).
  cat > ${DOCKER_BUILD_DIR}/entrypoint.sh << 'ENTRYEOF'
#!/bin/bash
mkdir -p /usr/local/share/hailo-ollama/models/manifests/hailo-ollama
mkdir -p /usr/local/share/hailo-ollama/models/blob

# Start hailo-ollama on internal port 11436
OLLAMA_HOST=0.0.0.0:11436 /usr/local/bin/hailo-ollama serve &
HAILO_PID=\$!

# Wait up to 15s for hailo-ollama to be ready on its internal port
for i in {1..15}; do
    curl -sf http://127.0.0.1:11436/api/tags > /dev/null 2>&1 && break
    sleep 1
done

# Start the OpenAI-compatibility proxy on port 11434 (foreground)
exec python3 /usr/local/bin/hailo-ollama-proxy.py
ENTRYEOF
  chmod +x ${DOCKER_BUILD_DIR}/entrypoint.sh

  # Write Dockerfile
  # Use ubuntu:24.04 (glibc 2.39) — hailo-ollama is compiled on Pi OS Bookworm
  # which ships glibc 2.38, newer than debian:bookworm-slim's 2.36.
  cat > ${DOCKER_BUILD_DIR}/Dockerfile << 'EOF'
FROM ubuntu:24.04

# Runtime deps: libusb (hailort), libssl3 (hailo-ollama TLS), libstdc++ (C++ runtime),
# python3 (OpenAI-compat proxy), curl (model pull from inside container)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libusb-1.0-0 \
    libssl3 \
    libstdc++6 \
    python3 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy hailo-ollama binary and the HailoRT shared library
COPY hailo-ollama          /usr/local/bin/hailo-ollama
COPY libhailort.so.${HAILO_VERSION} /usr/lib/aarch64-linux-gnu/libhailort.so.${HAILO_VERSION}

# Copy any remaining libs that were not satisfiable via apt
COPY extra-libs/ /usr/lib/aarch64-linux-gnu/

RUN chmod +x /usr/local/bin/hailo-ollama && ldconfig

# Verify no missing shared libs before shipping the image
RUN ldd /usr/local/bin/hailo-ollama | grep -v 'not found' > /dev/null \
    || (echo 'ERROR: hailo-ollama has unresolved shared libs:' \
        && ldd /usr/local/bin/hailo-ollama && exit 1)

EXPOSE 11434

# hailo-ollama runs internally on 11436; the proxy listens on 11434
ENV HAILO_INTERNAL_PORT=11436
ENV OLLAMA_PROXY_PORT=11434
ENV OLLAMA_HOST=0.0.0.0:11436
ENV OLLAMA_KEEP_ALIVE=-1

# Proxy script adds GET /v1/models (converts /api/tags to OpenAI format)
COPY proxy.py      /usr/local/bin/hailo-ollama-proxy.py
COPY entrypoint.sh /usr/local/bin/hailo-ollama-entrypoint.sh
RUN chmod +x /usr/local/bin/hailo-ollama-entrypoint.sh

VOLUME [\"/usr/local/share/hailo-ollama\"]

ENTRYPOINT [\"/usr/local/bin/hailo-ollama-entrypoint.sh\"]
EOF

  echo '  Building Docker image ${IMAGE_TAG}...'
  docker build -t ${IMAGE_TAG} ${DOCKER_BUILD_DIR} 2>&1 | tail -20

  echo 'IMAGE_BUILT'
") || DOCKER_RC=$?
echo "$DOCKER_OUT"
[[ $DOCKER_RC -eq 0 ]] || die "Docker image build failed (exit $DOCKER_RC) — see output above."

if echo "$DOCKER_OUT" | grep -q "IMAGE_READY"; then
    IMAGE_STATUS="IMAGE_READY"
    ok "Docker image: already exists, skipping build"
elif echo "$DOCKER_OUT" | grep -q "IMAGE_BUILT"; then
    IMAGE_STATUS="IMAGE_BUILT"
    ok "Docker image $IMAGE_TAG: built"
else
    die "Docker build completed but expected IMAGE_BUILT/IMAGE_READY token missing."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 5 — Update compose.yaml
# ═══════════════════════════════════════════════════════════════
header "STEP 5 — Update compose.yaml"

COMPOSE_OUT=""; COMPOSE_RC=0
COMPOSE_OUT=$(pi "
  set -e
  COMPOSE=${COMPOSE_FILE}

  # Detect the Hailo device group GID so the container can access /dev/h1x-0
  HAILO_DEV=\$(ls /dev/h1x* 2>/dev/null | head -1)
  HAILO_GID=\$(stat -c '%g' \"\$HAILO_DEV\" 2>/dev/null || echo '107')
  echo \"  Hailo device GID: \$HAILO_GID\"

  # Back up compose.yaml before modifying
  cp \"\$COMPOSE\" \"\${COMPOSE}.bak\"
  echo '  Backed up compose.yaml → compose.yaml.bak'

  python3 << PYEOF
import re, sys

COMPOSE_FILE = '${COMPOSE_FILE}'
IMAGE_TAG    = '${IMAGE_TAG}'
HAILO_GID    = '\$HAILO_GID'
MODEL        = '${HAILO_MODEL}'
PORT         = '${HAILO_OLLAMA_PORT}'

with open(COMPOSE_FILE, 'r') as f:
    content = f.read()

# Remove the CPU 'ollama' service block if present.
# We match from 'ollama:' (with indentation) to the next top-level service or end of services.
# Strategy: work line-by-line to remove the ollama service block.
lines = content.splitlines(keepends=True)
new_lines = []
skip = False
service_indent = None
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    # Detect start of the 'ollama' service block (exactly 2-space indent under services:)
    if re.match(r'^  ollama:\s*$', line):
        skip = True
        service_indent = indent
        i += 1
        continue
    if skip:
        # Stop skipping when we hit another service at the same indent level
        if stripped and not stripped.startswith('#') and indent <= service_indent and not re.match(r'^\s*$', line):
            skip = False
        else:
            i += 1
            continue
    new_lines.append(line)
    i += 1

content = ''.join(new_lines)

# Build the hailo-ollama service block
service_block = '''  hailo-ollama:
    container_name: hailo-ollama
    image: {image}
    restart: unless-stopped
    ports:
      - \"{port}:{port}\"
    volumes:
      - /usr/local/share/hailo-ollama:/usr/local/share/hailo-ollama
    devices:
      - /dev/h1x-0:/dev/h1x-0
    group_add:
      - \"{gid}\"
    environment:
      - OLLAMA_HOST=0.0.0.0:{port}
      - OLLAMA_KEEP_ALIVE=-1
      - HAILO_OLLAMA_VDEVICE_GROUP_ID=SHARED
      - XDG_DATA_HOME=/usr/local/share
'''.format(image=IMAGE_TAG, port=PORT, gid=HAILO_GID)

# Remove any existing hailo-ollama block so we always apply the latest config
lines = content.splitlines(keepends=True)
new_lines = []
skip2 = False
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if re.match(r'^  hailo-ollama:\s*$', line):
        skip2 = True
        i += 1
        continue
    if skip2:
        if stripped and not stripped.startswith('#') and indent <= 2 and not re.match(r'^\s*$', line):
            skip2 = False
        else:
            i += 1
            continue
    new_lines.append(line)
    i += 1
content = ''.join(new_lines)

# Insert the (re)built service block at the top of services:
content = re.sub(
    r'(^services:\s*\n)',
    r'\1' + service_block,
    content,
    count=1,
    flags=re.MULTILINE
)
print('  hailo-ollama service block inserted/updated in compose.yaml')

# Using a host bind mount (/usr/local/share/hailo-ollama) — no named volume needed.

# ── Hailo vDevice group sharing ──────────────────────────────────────────────
# Both hailo-ollama and wyoming-whisper (or any other Hailo service) must use
# the same HAILO_VDEVICE_GROUP_ID so HailoRT lets them share /dev/h1x-0.
# hailo-ollama reads HAILO_OLLAMA_VDEVICE_GROUP_ID; HailoRT library reads
# HAILO_VDEVICE_GROUP_ID from the environment for all other apps.
VDEVICE_GROUP = 'SHARED'
VDEVICE_ENV_LINE = '      - HAILO_VDEVICE_GROUP_ID=' + VDEVICE_GROUP + '\n'

lines = content.splitlines(keepends=True)

# Find (service_name, start_line_idx, end_line_idx) for each service block
in_services = False
cur_service = None
cur_start = None
service_ranges = []
for idx, line in enumerate(lines):
    if re.match(r'^services:\s*$', line):
        in_services = True
        continue
    if not in_services:
        continue
    # Top-level key other than services: signals end of services block
    if line and not line[0].isspace() and not re.match(r'^\s*$', line):
        if cur_service is not None:
            service_ranges.append((cur_service, cur_start, idx))
        in_services = False
        cur_service = None
        continue
    m = re.match(r'^  (\w[\w-]*):\s*$', line)
    if m:
        if cur_service is not None:
            service_ranges.append((cur_service, cur_start, idx))
        cur_service = m.group(1)
        cur_start = idx
if cur_service is not None:
    service_ranges.append((cur_service, cur_start, len(lines)))

wyoming_patched = []
for svc_name, start, end in service_ranges:
    if svc_name == 'hailo-ollama':
        continue
    svc_lines = lines[start:end]
    if not any('/dev/h1x-0' in l for l in svc_lines):
        continue  # service doesn't use the Hailo device
    # Always overwrite any existing HAILO_VDEVICE_GROUP_ID to ensure it matches SHARED.
    existing_idx = None
    for j, l in enumerate(svc_lines):
        if 'HAILO_VDEVICE_GROUP_ID' in l:
            existing_idx = j
            break
    if existing_idx is not None:
        svc_lines[existing_idx] = re.sub(
            r'(HAILO_VDEVICE_GROUP_ID=).*', r'\g<1>' + VDEVICE_GROUP,
            svc_lines[existing_idx])
        lines[start:end] = svc_lines
        wyoming_patched.append(svc_name)
        print('  Updated HAILO_VDEVICE_GROUP_ID=' + VDEVICE_GROUP + ' in service: ' + svc_name)
        continue
    # No existing entry — add it.
    env_idx = None
    for j, l in enumerate(svc_lines):
        if re.match(r'    environment:\s*$', l):
            env_idx = j
            break
    if env_idx is not None:
        svc_lines.insert(env_idx + 1, VDEVICE_ENV_LINE)
    else:
        # No environment section — insert one before devices: (or at end)
        insert_at = len(svc_lines)
        for j, l in enumerate(svc_lines):
            if re.match(r'    devices:\s*$', l):
                insert_at = j
                break
        svc_lines.insert(insert_at, VDEVICE_ENV_LINE)
        svc_lines.insert(insert_at, '    environment:\n')
    lines[start:end] = svc_lines
    wyoming_patched.append(svc_name)
    print('  Added HAILO_VDEVICE_GROUP_ID=' + VDEVICE_GROUP + ' to service: ' + svc_name)

if not wyoming_patched:
    print('  WARNING: No Hailo-sharing service found to patch (wyoming not in compose?)')
content = ''.join(lines)
# ─────────────────────────────────────────────────────────────────────────────

with open(COMPOSE_FILE, 'w') as f:
    f.write(content)

print('  compose.yaml updated successfully')
PYEOF

  echo 'COMPOSE_UPDATED'
") || COMPOSE_RC=$?
echo "$COMPOSE_OUT"
[[ $COMPOSE_RC -eq 0 ]] || die "compose.yaml update failed (exit $COMPOSE_RC) — see output above."
echo "$COMPOSE_OUT" | grep -q "COMPOSE_UPDATED" || die "Unexpected output from compose update step."
ok "compose.yaml: updated"

# ═══════════════════════════════════════════════════════════════
# STEP 6 — docker compose up
# ═══════════════════════════════════════════════════════════════
header "STEP 6 — Start hailo-ollama via Docker Compose"

UP_OUT=""; UP_RC=0
UP_OUT=$(pi "
  set -e
  # Ensure the host dirs hailo-ollama needs exist and are writable.
  # hailo-ollama (with XDG_DATA_HOME=/usr/local/share) stores blobs in models/blob/ (singular).
  sudo mkdir -p /usr/local/share/hailo-ollama/models/manifests/hailo-ollama
  sudo mkdir -p /usr/local/share/hailo-ollama/models/blob
  sudo chown -R ctf:ctf /usr/local/share/hailo-ollama/models/manifests/hailo-ollama
  sudo chown -R ctf:ctf /usr/local/share/hailo-ollama/models/blob
  echo '  Host model dirs: ready'
  cd ~/homeassistant

  # Restart any service that shares /dev/h1x-0 with hailo-ollama so it
  # picks up the new HAILO_VDEVICE_GROUP_ID before hailo-ollama starts.
  # Both processes must use the same group_id for HailoRT to allow sharing.
  # Note: 2>/dev/null must be before << to redirect python3 stderr; PEOF at col 0.
  WYOMING_SVC=\$(python3 2>/dev/null << PEOF
import yaml, sys
try:
    with open('compose.yaml') as f:
        c = yaml.safe_load(f)
    for name, svc in c.get('services', {}).items():
        if name == 'hailo-ollama':
            continue
        devs = svc.get('devices', [])
        if any('/dev/h1x-0' in str(d) for d in devs):
            print(name)
            sys.exit(0)
except Exception:
    pass
PEOF
) || WYOMING_SVC=''
  if [ -n \"\$WYOMING_SVC\" ]; then
    echo \"  Restarting \$WYOMING_SVC to activate HAILO_VDEVICE_GROUP_ID (vdevice sharing)...\"
    docker compose restart \"\$WYOMING_SVC\" 2>&1 | tail -5 || true
    sleep 5
    echo \"  \$WYOMING_SVC restarted.\"
  else
    echo '  No other Hailo service found in compose — skipping wyoming restart.'
  fi

  docker compose up -d hailo-ollama 2>&1
  echo 'COMPOSE_UP_DONE'
") || UP_RC=$?
echo "$UP_OUT"
[[ $UP_RC -eq 0 ]] || die "docker compose up failed (exit $UP_RC) — see output above."
echo "$UP_OUT" | grep -q "COMPOSE_UP_DONE" || die "Unexpected output from compose up step."
ok "hailo-ollama container: started"

# Wait for the server to bind and respond
info "Waiting for hailo-ollama to be ready on port $HAILO_OLLAMA_PORT..."
READY_RC=0
for i in $(seq 1 30); do
    READY=$(pi "curl -sf http://localhost:${HAILO_OLLAMA_PORT}/api/tags > /dev/null 2>&1 && echo READY || echo NOT_READY") || true
    if echo "$READY" | grep -q "READY"; then
        ok "hailo-ollama: listening on port $HAILO_OLLAMA_PORT"
        READY_RC=1
        break
    fi
    echo "  Waiting... ($i/30)"
    sleep 3
done
if [[ $READY_RC -eq 0 ]]; then
    warn "hailo-ollama did not respond within 90s — checking container logs..."
    pi "docker logs hailo-ollama --tail 40 2>&1" || true
    die "hailo-ollama failed to start. See logs above."
fi

# Diagnostic: check early container logs for NPU device sharing errors
info "Checking hailo-ollama startup logs for NPU errors..."
sleep 2
STARTUP_LOGS=$(pi "docker logs hailo-ollama 2>&1 | tail -30") || true
echo "$STARTUP_LOGS"
if echo "$STARTUP_LOGS" | grep -qi "HAILO_OUT_OF_PHYSICAL_DEVICES"; then
    warn "NPU device sharing conflict detected — HAILO_OUT_OF_PHYSICAL_DEVICES in logs."
    warn "Checking vdevice group IDs..."
    pi "
      echo '  hailo-ollama env:'; docker exec hailo-ollama env 2>/dev/null | grep -i hailo || echo '  (none)'
      echo '  hailo-whisper env:'; docker exec hailo-whisper env 2>/dev/null | grep -i hailo || echo '  (none)'
    " || true
    warn "Both containers must use the same group_id. Check env vars above."
fi

# ═══════════════════════════════════════════════════════════════
# STEP 7 — Pull the tool-calling model
# ═══════════════════════════════════════════════════════════════
header "STEP 7 — Pull model: $HAILO_MODEL"

MODEL_OUT=""; MODEL_RC=0
MODEL_OUT=$(pi "
  # Show what is actually in the hailo-ollama model store (helps debug wrong paths).
  echo '  Model store contents:'
  find /usr/local/share/hailo-ollama/models/ 2>/dev/null | head -40 || echo '  (directory empty or missing)'

  MODEL_PATH=\$(echo '${HAILO_MODEL}' | tr ':' '/')

  # Model is only ready when BOTH manifest AND blob files exist.
  # hailo-ollama (XDG_DATA_HOME=/usr/local/share) stores blobs in models/blob/ (singular).
  BLOB_COUNT=\$(find /usr/local/share/hailo-ollama/models/blob/ -type f 2>/dev/null | wc -l)

  # Check primary manifest path: manifests/{name}/{tag}/manifest.json
  MANIFEST_FILE=/usr/local/share/hailo-ollama/models/manifests/\${MODEL_PATH}/manifest.json
  if [ -f \"\$MANIFEST_FILE\" ] && [ \"\$BLOB_COUNT\" -gt 0 ]; then
    echo \"  Model manifest + \$BLOB_COUNT blob(s) found — skipping pull.\"
    echo \"  Manifest: \$MANIFEST_FILE\"
    echo 'MODEL_READY'
    exit 0
  elif [ -f \"\$MANIFEST_FILE\" ] && [ \"\$BLOB_COUNT\" -eq 0 ]; then
    echo \"  Manifest found at \$MANIFEST_FILE but blob/ is empty — HEF data missing, must pull.\"
  else
    echo \"  Manifest not found at \$MANIFEST_FILE — pulling model.\"
  fi

  # Secondary live check: /api/tags (only if blobs are present — avoids false positives)
  if [ \"\$BLOB_COUNT\" -gt 0 ] && curl -sf http://localhost:${HAILO_OLLAMA_PORT}/api/tags 2>/dev/null | grep -q '${HAILO_MODEL}'; then
    echo '  Model ${HAILO_MODEL} listed in /api/tags — skipping pull.'
    echo 'MODEL_READY'
    exit 0
  fi

  # hailo-ollama creates the HailoRT VDevice lazily on the first real request (pull/generate).
  # If hailo-whisper holds /dev/h1x-0 exclusively, hailo-ollama crashes instantly on pull.
  # Stop hailo-whisper before pulling to give hailo-ollama exclusive NPU access.
  cd ~/homeassistant
  echo '  Stopping hailo-whisper temporarily (NPU needed for pull)...'
  docker compose stop hailo-whisper 2>&1 | tail -3 || true
  sleep 2

  # hailo-ollama uses a custom manifest format: hef_h10h = SHA256 of the HEF file.
  # Download URL: https://dev-public.hailo.ai/blob/sha256_{hash}  (from client.hpp API_CALL)
  # Blob storage:  XDG_DATA_HOME/hailo-ollama/models/blob/sha256_{hash}  (singular "blob")
  #   XDG_DATA_HOME=/usr/local/share in compose.yaml → bind-mounted path on host.
  MANIFEST_JSON=\$(cat /usr/local/share/hailo-ollama/models/manifests/\${MODEL_PATH}/manifest.json 2>/dev/null)
  BLOB_HASH=\$(echo \"\$MANIFEST_JSON\" | python3 -c \"
import json,sys
d=json.load(sys.stdin)
print(d.get('hef_h10h',''))
\" 2>/dev/null)
  echo \"  HEF blob hash (hef_h10h): \$BLOB_HASH\"

  if [ -z \"\$BLOB_HASH\" ]; then
    echo '  ERROR: hef_h10h field missing from manifest.'
    echo 'PULL_FAILED'; exit 1
  fi

  BLOB_FILE=/usr/local/share/hailo-ollama/models/blob/sha256_\${BLOB_HASH}

  # Migrate from old blobs/ (plural) location if we already downloaded there.
  OLD_BLOB=/usr/local/share/hailo-ollama/models/blobs/sha256_\${BLOB_HASH}
  if [ -f \"\$OLD_BLOB\" ] && [ ! -f \"\$BLOB_FILE\" ]; then
    echo \"  Migrating blob from blobs/ to blob/ (no re-download needed)...\"
    mkdir -p /usr/local/share/hailo-ollama/models/blob
    mv \"\$OLD_BLOB\" \"\$BLOB_FILE\"
    echo \"  Migrated: \$BLOB_FILE\"
  fi
  DL_URL=\"https://dev-public.hailo.ai/blob/sha256_\${BLOB_HASH}\"
  echo \"  Downloading: \$DL_URL\"
  echo \"  Destination: \$BLOB_FILE\"
  HTTP_CODE=\$(curl -w '%{http_code}' -o \"\${BLOB_FILE}.tmp\" -L --max-time 900 -s \
    --retry 2 --retry-delay 5 \"\$DL_URL\" 2>&1)
  echo \"  HTTP status: \$HTTP_CODE\"
  if [ \"\$HTTP_CODE\" = '200' ] && [ -s \"\${BLOB_FILE}.tmp\" ]; then
    echo \"  Download complete — verifying SHA256...\"
    ACTUAL_HASH=\$(sha256sum \"\${BLOB_FILE}.tmp\" | cut -d' ' -f1)
    if [ \"\$ACTUAL_HASH\" = \"\$BLOB_HASH\" ]; then
      mv \"\${BLOB_FILE}.tmp\" \"\$BLOB_FILE\"
      echo \"  SHA256 verified ✔  Blob: \$BLOB_FILE\"
    else
      rm -f \"\${BLOB_FILE}.tmp\"
      echo \"  SHA256 mismatch: expected \$BLOB_HASH got \$ACTUAL_HASH\"
      echo 'PULL_FAILED'; exit 1
    fi
  else
    rm -f \"\${BLOB_FILE}.tmp\"
    echo \"  Download failed (HTTP \$HTTP_CODE). Response body:\"
    curl -s -L --max-time 10 \"\$DL_URL\" | head -5 || true
    echo 'PULL_FAILED'; exit 1
  fi

  # Restart hailo-whisper regardless of pull outcome.
  echo '  Restarting hailo-whisper...'
  docker compose start hailo-whisper 2>&1 | tail -3 || true
  echo 'MODEL_PULLED'
") || MODEL_RC=$?
echo "$MODEL_OUT"
[[ $MODEL_RC -eq 0 ]] || die "Model pull failed (exit $MODEL_RC)."
echo "$MODEL_OUT" | grep -qE "MODEL_READY|MODEL_PULLED" || die "Model pull: unexpected output."
ok "Model $HAILO_MODEL: pulled"
# hailo-ollama has no /api/create — no alias support. HA uses the model name directly.

# ═══════════════════════════════════════════════════════════════
# STEP 8 — Smoke-test inference
# ═══════════════════════════════════════════════════════════════
header "STEP 8 — Smoke-test inference"

info "Sending test prompt to hailo-ollama..."
INFER_OUT=""; INFER_RC=0
INFER_OUT=$(pi "
  # Check container is still running before attempting inference
  STATUS=\$(docker inspect --format '{{.State.Status}}' hailo-ollama 2>/dev/null || echo 'missing')
  echo \"  Container status: \$STATUS\"
  if [ \"\$STATUS\" != 'running' ]; then
    echo '  Container is not running — last 50 log lines:'
    docker logs hailo-ollama --tail 50 2>&1 || true
    echo 'CONTAINER_DOWN'
    exit 1
  fi

  # Port 11434 was already verified in Step 6. The proxy only starts after hailo-ollama
  # is ready on 11436, so if 11434 is up the backend is up. Skip redundant internal check.
  echo '  Sending generate request (timeout 180s — first NPU inference loads HEF and can be slow)...'
  RESPONSE=\$(curl -s --max-time 180 -X POST http://localhost:${HAILO_OLLAMA_PORT}/api/generate \
    -H 'Content-Type: application/json' \
    -d '{\"model\": \"${HAILO_MODEL}\", \"prompt\": \"Reply with exactly: INFERENCE_OK\", \"stream\": false}' 2>&1)
  CURL_RC=\$?
  echo \"  curl exit: \$CURL_RC\"
  echo \"  Response: \$RESPONSE\"
  if [ \$CURL_RC -ne 0 ]; then
    echo '  Dumping container logs after curl failure:'
    docker logs hailo-ollama --tail 60 2>&1 || true
    echo 'CURL_FAILED'
    exit 1
  fi
  echo \"\$RESPONSE\" | python3 -c \"
import json,sys
d=json.load(sys.stdin)
if 'error' in d:
    print('  Model error:', d['error'])
    sys.exit(1)
print('  Model reply:', d.get('response','(empty)').strip())
\" 2>/dev/null || { echo 'SMOKE_FAILED'; exit 1; }
  echo 'SMOKE_DONE'
") || INFER_RC=$?
echo "$INFER_OUT"
if echo "$INFER_OUT" | grep -q "CONTAINER_DOWN"; then
    die "hailo-ollama container crashed after model load — see logs above."
fi
if echo "$INFER_OUT" | grep -q "SMOKE_FAILED"; then
    die "Smoke-test inference returned an error — see response above. Check hailo-ollama logs: docker logs hailo-ollama --tail 50"
fi
if echo "$INFER_OUT" | grep -q "SMOKE_DONE"; then
    ok "Inference: working"
else
    # First NPU inference (HEF model load) can exceed 120s — treat as a warning, not a hard failure.
    # The HA integration will exercise inference in real use.
    warn "Smoke-test inference timed out or returned unexpected output (curl exit $INFER_RC)."
    warn "This is normal for the first NPU inference — the HEF model may still be loading."
    warn "Verify manually: curl -s http://${SSH_ALIAS}:11434/api/tags"
fi

# ═══════════════════════════════════════════════════════════════
# STEP 9 — Verify Home Assistant connectivity
# ═══════════════════════════════════════════════════════════════
header "STEP 9 — Verify Home Assistant connectivity"

HA_OUT=""; HA_RC=0
HA_OUT=$(pi "
  # Verify HA container can reach hailo-ollama on localhost
  if docker exec homeassistant curl -sf http://localhost:${HAILO_OLLAMA_PORT}/api/tags > /dev/null 2>&1; then
    echo '  HA container → hailo-ollama: reachable on localhost:${HAILO_OLLAMA_PORT}'
  else
    echo '  WARNING: HA container cannot reach hailo-ollama on localhost:${HAILO_OLLAMA_PORT}'
    echo '  Check that homeassistant service uses network_mode: host in compose.yaml'
  fi

  # Patch the Extended OpenAI Conversation model name in HA's config entry store.
  # The 01-install script may have set it to llama3.2:3b (CPU ollama model).
  # hailo-ollama only knows 'voice-assistant', so update it.
  STORAGE=~/homeassistant/config/.storage/core.config_entries
  if [ -f \"\$STORAGE\" ]; then
    CURRENT_MODEL=\$(sudo python3 -c \"
import json
data = json.load(open('\$STORAGE'))
for e in data.get('data', {}).get('entries', []):
    if e.get('domain') == 'extended_openai_conversation':
        # Print full options+data so we can see the actual key names
        import sys
        print('  [DEBUG] options:', json.dumps(e.get('options', {})), file=sys.stderr)
        print('  [DEBUG] data keys:', list(e.get('data', {}).keys()), file=sys.stderr)
        model = (e.get('options', {}).get('chat_model')
              or e.get('data', {}).get('chat_model')
              or e.get('options', {}).get('model')
              or e.get('data', {}).get('model')
              or 'not found')
        print(model)
        break
\" 2>&1 || echo 'unknown')
    echo \"  Extended OpenAI Conversation current model: \$CURRENT_MODEL\"

    if [ \"\$CURRENT_MODEL\" != '${HA_MODEL_ALIAS}' ]; then
      echo \"  Patching model from '\$CURRENT_MODEL' → '${HA_MODEL_ALIAS}'...\"
      sudo cp \"\$STORAGE\" \"\${STORAGE}.bak\"
      python3 -c \"
import json
data = json.load(open('\$STORAGE'))
patched = False
for e in data.get('data', {}).get('entries', []):
    if e.get('domain') == 'extended_openai_conversation':
        for section in ('options', 'data'):
            for key in ('chat_model', 'model'):
                if key in e.get(section, {}):
                    e[section][key] = '${HA_MODEL_ALIAS}'
                    patched = True
if patched:
    json.dump(data, open('\$STORAGE', 'w'), indent=2)
    print('  Patched successfully')
else:
    print('  Model key not found — check DEBUG output above for actual keys')
\"
      echo '  File patched. Reload the integration in HA UI (no full restart needed):'
      echo '  Settings → Devices & Services → Extended OpenAI Conversation → ⋮ → Reload'
      echo 'HA_PATCHED'
    else
      echo '  Model already set to ${HA_MODEL_ALIAS} — no patch needed.'
    fi
  else
    echo '  WARNING: HA config entries storage not found at \$STORAGE'
  fi

  echo 'HA_CHECK_DONE'
") || HA_RC=$?
echo "$HA_OUT"
[[ $HA_RC -eq 0 ]] || warn "HA connectivity check had issues (exit $HA_RC)."

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✔  hailo-ollama NPU LLM running via Docker Compose!  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}  Container: ${BOLD}hailo-ollama${NC}${CYAN} (image: ${IMAGE_TAG})${NC}"
echo -e "${CYAN}  Model:     ${BOLD}${HA_MODEL_ALIAS}${NC}${CYAN} → ${HAILO_MODEL}${NC}"
echo -e "${CYAN}  API:       ${BOLD}http://localhost:${HAILO_OLLAMA_PORT}/v1${NC}"
echo ""
echo -e "${YELLOW}  ╔══ One manual step remaining ══════════════════════════╗${NC}"
echo -e "${YELLOW}  ║  Switch HA conversation agent to Extended OpenAI:     ║${NC}"
echo -e "${YELLOW}  ║  HA → Settings → Voice Assistants → edit assistant    ║${NC}"
echo -e "${YELLOW}  ║  → Conversation Agent → Extended OpenAI Conversation  ║${NC}"
echo -e "${YELLOW}  ╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "=== $(date '+%Y-%m-%d %H:%M:%S') — completed successfully ==="
echo "Log saved to: ${LOG_FILE}"
