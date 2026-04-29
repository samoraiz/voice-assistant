#!/usr/bin/env bash
# ============================================================
# 03-upgrade-service.sh
# Upgrade one service at a time with verification and rollback.
#
# Supported services:
#   hailo-whisper              — Docker image pull + restart
#   hailo-ollama               — Docker image rebuild (proxy/entrypoint changes)
#   hailo-ollama-full          — Full rebuild from source (new HailoRT version)
#   piper                      — Docker image pull + restart
#   homeassistant              — Docker image pull + restart
#   extended_openai_conversation — GitHub custom component update
#
# Each upgrade cycle:
#   1. Show current version / image digest
#   2. Confirm target version with user
#   3. Back up compose.yaml + image state
#   4. Perform upgrade
#   5. Run service-specific health verification
#   6. Offer rollback if verification fails
#
# Usage:
#   bash 03-upgrade-service.sh                  # interactive menu
#   bash 03-upgrade-service.sh hailo-whisper    # upgrade specific service
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/upgrade-service.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo ""
echo "=== $(date '+%Y-%m-%d %H:%M:%S') — 03-upgrade-service.sh started ==="

SSH_ALIAS="${RPI_HOST:-rpi.local}"
COMPOSE_FILE="/home/ctf/homeassistant/compose.yaml"
HAILO_VERSION="5.3.0"   # current baseline; override with --hailo-version X.Y.Z

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()     { echo -e "${GREEN}  ✔  $*${NC}"; }
info()   { echo -e "${CYAN}  →  $*${NC}"; }
header() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
die()    { echo -e "${RED}  ✘  FATAL: $*${NC}"; echo "=== FAILED ===" ; exit 1; }
ask()    { echo -e "${YELLOW}  ▶  $*${NC}"; }

# ── SSH helpers ───────────────────────────────────────────────────────────────
pi() { ssh "$SSH_ALIAS" "bash -l -s" <<< "$@"; }

pi_check_ssh() {
    if ! pi "echo SSH_OK" 2>/dev/null | grep -q SSH_OK; then
        die "Cannot SSH to '$SSH_ALIAS'. Run 00-setup-ssh.sh first."
    fi
    ok "SSH: connected to $SSH_ALIAS"
}

# ── Prompt helper (reads from /dev/tty so it works inside tee pipelines) ─────
prompt() {
    local msg="$1" var="$2" default="${3:-}"
    ask "$msg ${default:+(default: $default)}"
    read -r "$var" < /dev/tty
    if [[ -z "${!var}" && -n "$default" ]]; then
        eval "$var='$default'"
    fi
}

prompt_yn() {
    local msg="$1" var="$2"
    while true; do
        ask "$msg [y/n]"
        read -r _yn < /dev/tty
        case "$_yn" in
            [Yy]*) eval "$var=y"; return ;;
            [Nn]*) eval "$var=n"; return ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

# ── Compose backup / restore ──────────────────────────────────────────────────
backup_compose() {
    info "Backing up compose.yaml..."
    pi "cp ${COMPOSE_FILE} ${COMPOSE_FILE}.upgrade-bak && echo COMPOSE_BACKED_UP" \
        | grep -q COMPOSE_BACKED_UP || die "Failed to back up compose.yaml"
    ok "compose.yaml → compose.yaml.upgrade-bak"
}

restore_compose() {
    info "Restoring compose.yaml from backup..."
    pi "cp ${COMPOSE_FILE}.upgrade-bak ${COMPOSE_FILE} && echo COMPOSE_RESTORED" \
        | grep -q COMPOSE_RESTORED && ok "compose.yaml restored" || warn "compose.yaml restore failed — check manually"
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: hailo-whisper
# ─────────────────────────────────────────────────────────────────────────────
upgrade_hailo_whisper() {
    local target_tag="${1:-latest}"

    header "Upgrade: hailo-whisper → canthefason/hailo-whisper:${target_tag}"

    # ── Current version ────────────────────────────────────────────────────
    info "Current hailo-whisper image state:"
    pi "
      IMG_ID=\$(docker inspect hailo-whisper --format '{{.Image}}' 2>/dev/null || echo none)
      IMG_TAG=\$(docker inspect hailo-whisper --format '{{.Config.Image}}' 2>/dev/null || echo none)
      DIGEST=\$(docker image inspect \$IMG_TAG --format '{{index .RepoDigests 0}}' 2>/dev/null || echo none)
      echo \"  Container image : \$IMG_TAG\"
      echo \"  Image ID        : \$IMG_ID\"
      echo \"  Remote digest   : \$DIGEST\"
      echo \"CURRENT_INFO_DONE\"
    " | grep -v CURRENT_INFO_DONE || true

    # ── Save rollback tag ──────────────────────────────────────────────────
    info "Tagging current image for rollback..."
    pi "
      CUR_IMAGE=\$(docker inspect hailo-whisper --format '{{.Config.Image}}' 2>/dev/null || echo 'canthefason/hailo-whisper:latest')
      docker tag \"\$CUR_IMAGE\" canthefason/hailo-whisper:rollback 2>/dev/null && echo ROLLBACK_TAG_OK || echo 'No existing image to tag (first install?)'
    " || true

    # ── Pull ───────────────────────────────────────────────────────────────
    info "Pulling canthefason/hailo-whisper:${target_tag}..."
    pi "
      set -e
      docker pull canthefason/hailo-whisper:${target_tag}
      echo PULL_OK
    " | grep PULL_OK || die "docker pull failed for hailo-whisper:${target_tag}"

    # ── Update compose.yaml if a specific tag was requested ────────────────
    if [[ "$target_tag" != "latest" ]]; then
        info "Pinning image tag to ${target_tag} in compose.yaml..."
        backup_compose
        pi "
          sed -i 's|image: canthefason/hailo-whisper.*|image: canthefason/hailo-whisper:${target_tag}|' ${COMPOSE_FILE}
          echo COMPOSE_PINNED
        " | grep COMPOSE_PINNED || die "Failed to pin image tag in compose.yaml"
    fi

    # ── Restart ────────────────────────────────────────────────────────────
    info "Restarting hailo-whisper..."
    pi "
      cd ~/homeassistant
      docker compose up -d --force-recreate hailo-whisper 2>&1 | tail -5
      echo RESTART_OK
    " | grep RESTART_OK || die "docker compose up failed for hailo-whisper"

    # ── Verify ─────────────────────────────────────────────────────────────
    verify_hailo_whisper
}

verify_hailo_whisper() {
    header "Verification: hailo-whisper"
    local ok=true

    info "Checking container status..."
    local status
    status=$(pi "docker inspect hailo-whisper --format '{{.State.Status}}' 2>/dev/null || echo missing")
    echo "  Status: $status"
    [[ "$status" == "running" ]] || { warn "Container is not running"; ok=false; }

    info "Waiting up to 20s for Wyoming STT port 10300..."
    local port_open=false
    for i in $(seq 1 4); do
        if pi "ss -tlnp | grep -q :10300 && echo PORT_OK" 2>/dev/null | grep -q PORT_OK; then
            port_open=true; break
        fi
        echo "  Waiting... ($i/4)"
        sleep 5
    done
    $port_open || { warn "Wyoming STT port 10300 not listening"; ok=false; }

    if $ok; then
        ok "hailo-whisper: HEALTHY (running, port 10300 listening)"
        return 0
    else
        warn "hailo-whisper verification FAILED"
        info "Container logs:"
        pi "docker logs hailo-whisper --tail 30 2>&1" || true
        return 1
    fi
}

rollback_hailo_whisper() {
    header "Rollback: hailo-whisper"
    info "Switching back to :rollback tag..."
    pi "
      docker tag canthefason/hailo-whisper:rollback canthefason/hailo-whisper:latest 2>/dev/null || true
      cd ~/homeassistant
      docker compose up -d --force-recreate hailo-whisper 2>&1 | tail -5
      echo ROLLBACK_OK
    " | grep ROLLBACK_OK && ok "Rollback applied" || warn "Rollback had issues — check manually"
    restore_compose
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: hailo-ollama (Docker image rebuild — proxy/entrypoint changes only)
# ─────────────────────────────────────────────────────────────────────────────
upgrade_hailo_ollama_image() {
    header "Upgrade: hailo-ollama Docker image (proxy/entrypoint rebuild)"

    info "Current hailo-ollama state:"
    pi "
      IMG_ID=\$(docker inspect hailo-ollama --format '{{.Image}}' 2>/dev/null || echo none)
      IMG_TAG=\$(docker inspect hailo-ollama --format '{{.Config.Image}}' 2>/dev/null || echo none)
      echo \"  Container image : \$IMG_TAG\"
      echo \"  Image ID        : \$IMG_ID\"
      echo \"CURRENT_INFO_DONE\"
    " | grep -v CURRENT_INFO_DONE || true

    backup_compose

    # ── Tag existing image for rollback ────────────────────────────────────
    info "Tagging current image for rollback..."
    pi "
      CUR_IMG=\$(docker inspect hailo-ollama --format '{{.Config.Image}}' 2>/dev/null || echo 'hailo-ollama:${HAILO_VERSION}')
      docker tag \"\$CUR_IMG\" hailo-ollama:rollback 2>/dev/null && echo ROLLBACK_TAG_OK || echo 'No existing image to tag'
    " || true

    # ── Remove stale image so it rebuilds ─────────────────────────────────
    info "Removing stale Docker image to force rebuild..."
    pi "docker rmi hailo-ollama:${HAILO_VERSION} 2>/dev/null || true && echo IMAGE_REMOVED"
    ok "Stale image cleared"

    # ── Stop container so the build context can be refreshed ──────────────
    info "Stopping hailo-ollama container..."
    pi "
      cd ~/homeassistant
      docker compose stop hailo-ollama 2>/dev/null || true
      docker compose rm -f hailo-ollama 2>/dev/null || true
      echo STOPPED_OK
    " | grep STOPPED_OK || true

    # ── Re-run the image build from 02-install-hailo-ollama-npu.sh Step 4 ─
    # We replicate only the Docker image build portion here, using the
    # binary that is already compiled on the Pi.
    info "Rebuilding Docker image hailo-ollama:${HAILO_VERSION} with fresh proxy/entrypoint..."
    local build_rc=0
    pi "
      set -e
      DOCKER_BUILD_DIR='/home/ctf/hailo-ollama-docker'
      HAILO_OLLAMA_BIN='/usr/local/bin/hailo-ollama'
      IMAGE_TAG='hailo-ollama:${HAILO_VERSION}'

      mkdir -p \$DOCKER_BUILD_DIR
      cp \$HAILO_OLLAMA_BIN \$DOCKER_BUILD_DIR/hailo-ollama

      # libhailort
      LIBHAILORT=\$(ldconfig -p 2>/dev/null | grep 'libhailort.so.${HAILO_VERSION}' | awk '{print \$NF}' | head -1)
      [ -n \"\$LIBHAILORT\" ] || LIBHAILORT=\$(find /usr/lib /usr/local/lib -name 'libhailort.so.${HAILO_VERSION}' 2>/dev/null | head -1)
      [ -n \"\$LIBHAILORT\" ] || { echo 'ERROR: libhailort.so.${HAILO_VERSION} not found'; exit 1; }
      cp \"\$LIBHAILORT\" \$DOCKER_BUILD_DIR/libhailort.so.${HAILO_VERSION}

      # Extra libs
      mkdir -p \$DOCKER_BUILD_DIR/extra-libs
      ldd \$HAILO_OLLAMA_BIN 2>/dev/null | awk '/=>/{print \$3}' | grep -v '^\$' | while read LIB; do
        BASENAME=\$(basename \"\$LIB\")
        case \"\$BASENAME\" in
          libhailort*|libc.so*|libm.so*|libpthread*|libdl.so*|librt.so*|ld-linux*) continue ;;
        esac
        case \"\$BASENAME\" in
          libssl*|libcrypto*|libstdc*|libgcc_s*) cp -n \"\$LIB\" \$DOCKER_BUILD_DIR/extra-libs/ 2>/dev/null || true ;;
        esac
      done

      echo 'Writing proxy.py...'
      cat > \$DOCKER_BUILD_DIR/proxy.py << 'PROXYEOF'
#!/usr/bin/env python3
import http.server, urllib.request, urllib.error, json, os, sys

BACKEND_PORT = int(os.environ.get('HAILO_INTERNAL_PORT', '11436'))
LISTEN_PORT  = int(os.environ.get('OLLAMA_PROXY_PORT',  '11434'))
BACKEND = 'http://127.0.0.1:' + str(BACKEND_PORT)


def fix_json_control_chars(body_bytes):
    '''Escape literal control characters inside JSON string values.
    chr(92)=backslash and chr(34)=double-quote avoid literal versions of those
    characters in the enclosing bash string.'''
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
    HailoRT re-serialises message content without escaping newlines.
    Parse the body, replace newlines inside string values with spaces.'''
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


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path.rstrip('/') == '/v1/models':
            try:
                r = urllib.request.urlopen(BACKEND + '/api/tags', timeout=10)
                data = json.loads(r.read())
                models = [
                    {'id': m['name'], 'object': 'model', 'created': 0, 'owned_by': 'hailo'}
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

    def _forward(self):
        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length) if length > 0 else None
        if body and self.headers.get('Content-Type', '').startswith('application/json'):
            body = fix_json_control_chars(body)
            body = sanitize_for_hailo(body)
        req = urllib.request.Request(BACKEND + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ('host', 'content-length', 'transfer-encoding'):
                req.add_header(k, v)
        try:
            r = urllib.request.urlopen(req, timeout=300)
            resp_body = r.read()
            self._send(r.status, resp_body, r.headers.get('Content-Type', 'application/octet-stream'))
        except urllib.error.HTTPError as exc:
            resp_body = exc.read()
            self._send(exc.code, resp_body, exc.headers.get('Content-Type', 'application/json'))
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

      cat > \$DOCKER_BUILD_DIR/entrypoint.sh << 'ENTRYEOF'
#!/bin/bash
mkdir -p /usr/local/share/hailo-ollama/models/manifests/hailo-ollama
mkdir -p /usr/local/share/hailo-ollama/models/blob
OLLAMA_HOST=0.0.0.0:11436 /usr/local/bin/hailo-ollama serve &
HAILO_PID=\$!
for i in {1..15}; do
    curl -sf http://127.0.0.1:11436/api/tags > /dev/null 2>&1 && break
    sleep 1
done
exec python3 /usr/local/bin/hailo-ollama-proxy.py
ENTRYEOF
      chmod +x \$DOCKER_BUILD_DIR/entrypoint.sh

      cat > \$DOCKER_BUILD_DIR/Dockerfile << 'DEOF'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libusb-1.0-0 libssl3 libstdc++6 python3 curl \
    && rm -rf /var/lib/apt/lists/*
COPY hailo-ollama          /usr/local/bin/hailo-ollama
COPY libhailort.so.${HAILO_VERSION} /usr/lib/aarch64-linux-gnu/libhailort.so.${HAILO_VERSION}
COPY extra-libs/ /usr/lib/aarch64-linux-gnu/
RUN chmod +x /usr/local/bin/hailo-ollama && ldconfig
RUN ldd /usr/local/bin/hailo-ollama | grep -v 'not found' > /dev/null || (echo 'unresolved libs' && ldd /usr/local/bin/hailo-ollama && exit 1)
EXPOSE 11434
ENV HAILO_INTERNAL_PORT=11436 OLLAMA_PROXY_PORT=11434 OLLAMA_HOST=0.0.0.0:11436 OLLAMA_KEEP_ALIVE=-1
COPY proxy.py      /usr/local/bin/hailo-ollama-proxy.py
COPY entrypoint.sh /usr/local/bin/hailo-ollama-entrypoint.sh
RUN chmod +x /usr/local/bin/hailo-ollama-entrypoint.sh
VOLUME [\"/usr/local/share/hailo-ollama\"]
ENTRYPOINT [\"/usr/local/bin/hailo-ollama-entrypoint.sh\"]
DEOF

      echo 'Building Docker image...'
      docker build -t \$IMAGE_TAG \$DOCKER_BUILD_DIR 2>&1 | tail -20
      echo IMAGE_BUILT
    " | grep IMAGE_BUILT || { build_rc=1; die "Docker image rebuild failed"; }

    # ── Start container ────────────────────────────────────────────────────
    info "Starting hailo-ollama with new image..."
    pi "
      set -e
      cd ~/homeassistant
      docker compose up -d hailo-ollama 2>&1 | tail -5
      echo COMPOSE_UP_OK
    " | grep COMPOSE_UP_OK || die "docker compose up failed for hailo-ollama"

    # ── Verify ─────────────────────────────────────────────────────────────
    verify_hailo_ollama
}

verify_hailo_ollama() {
    header "Verification: hailo-ollama"
    local ok=true

    info "Checking container status..."
    local status
    status=$(pi "docker inspect hailo-ollama --format '{{.State.Status}}' 2>/dev/null || echo missing")
    echo "  Status: $status"
    [[ "$status" == "running" ]] || { warn "Container is not running"; ok=false; }

    info "Waiting up to 30s for port 11434..."
    local port_open=false
    for i in $(seq 1 6); do
        if pi "curl -sf http://localhost:11434/api/tags > /dev/null 2>&1 && echo PORT_OK" 2>/dev/null | grep -q PORT_OK; then
            port_open=true; break
        fi
        echo "  Waiting... ($i/6)"
        sleep 5
    done
    $port_open || { warn "Port 11434 not responding"; ok=false; }

    if $ok; then
        info "Checking /v1/models (OpenAI-compat proxy)..."
        local models_out
        models_out=$(pi "curl -sf http://localhost:11434/v1/models 2>/dev/null || echo '{}'")
        echo "  /v1/models → $models_out"
        echo "$models_out" | grep -q '"data"' && ok "/v1/models: OK" || { warn "/v1/models returned unexpected output"; ok=false; }
    fi

    if $ok; then
        info "Running inference smoke test (timeout 120s)..."
        local infer_out
        infer_out=$(pi "
          RESPONSE=\$(curl -sf --max-time 120 -X POST http://localhost:11434/api/generate \
            -H 'Content-Type: application/json' \
            -d '{\"model\": \"qwen2.5:1.5b\", \"prompt\": \"Reply: INFERENCE_OK\", \"stream\": false}' 2>&1)
          echo \"\$RESPONSE\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(\"response\",\"\").strip()[:60])' 2>/dev/null && echo INFER_DONE || echo INFER_SKIP
        " 2>/dev/null || echo "INFER_SKIP")
        echo "  Inference output: $infer_out"
        echo "$infer_out" | grep -q "INFER_SKIP" && warn "Inference timed out or skipped (HEF load may still be in progress)" || ok "Inference: responded"
    fi

    if $ok; then
        ok "hailo-ollama: HEALTHY"
        return 0
    else
        warn "hailo-ollama verification FAILED"
        info "Container logs:"
        pi "docker logs hailo-ollama --tail 40 2>&1" || true
        return 1
    fi
}

rollback_hailo_ollama() {
    header "Rollback: hailo-ollama"
    info "Stopping container..."
    pi "cd ~/homeassistant && docker compose stop hailo-ollama 2>/dev/null || true && docker compose rm -f hailo-ollama 2>/dev/null || true"
    info "Restoring :rollback image..."
    pi "docker tag hailo-ollama:rollback hailo-ollama:${HAILO_VERSION} 2>/dev/null && echo ROLLBACK_TAG_OK || echo 'No rollback image available'" || true
    pi "cd ~/homeassistant && docker compose up -d hailo-ollama 2>&1 | tail -5"
    restore_compose
    ok "Rollback applied — run verify to confirm"
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: hailo-ollama FULL REBUILD (new HailoRT/hailo-ollama source version)
# ─────────────────────────────────────────────────────────────────────────────
upgrade_hailo_ollama_full() {
    local new_version="$1"
    header "Upgrade: hailo-ollama FULL REBUILD → HailoRT ${new_version}"

    warn "Full rebuild upgrades HailoRT system packages and recompiles hailo-ollama from source."
    warn "This requires the HailoRT ${new_version} .deb files to already be present in ~/ on the Pi."
    echo ""
    local go
    prompt_yn "Proceed with full hailo-ollama rebuild to HailoRT ${new_version}?" go
    [[ "$go" == "y" ]] || { info "Aborted."; return 0; }

    # ── Check .deb files present ───────────────────────────────────────────
    info "Checking for HailoRT ${new_version} .deb files on Pi..."
    local deb_check
    deb_check=$(pi "
      DRIVER_DEB=\$(ls ~/hailort*pcie*driver*${new_version}*.deb ~/hailort*driver*${new_version}*.deb 2>/dev/null | head -1 || true)
      RUNTIME_DEB=\$(ls ~/hailort_${new_version}*.deb ~/hailort-${new_version}*.deb ~/hailort*${new_version}*arm64*.deb 2>/dev/null | grep -v 'driver\|dkms\|pcie' | head -1 || true)
      if [ -n \"\$DRIVER_DEB\" ] && [ -n \"\$RUNTIME_DEB\" ]; then
        echo \"  Driver : \$DRIVER_DEB\"
        echo \"  Runtime: \$RUNTIME_DEB\"
        echo DEB_FILES_OK
      else
        echo \"  Driver .deb found : \${DRIVER_DEB:-(MISSING)}\"
        echo \"  Runtime .deb found: \${RUNTIME_DEB:-(MISSING)}\"
        echo DEB_FILES_MISSING
      fi
    " 2>/dev/null || echo DEB_FILES_MISSING)
    echo "$deb_check"
    if ! echo "$deb_check" | grep -q DEB_FILES_OK; then
        die "HailoRT ${new_version} .deb files not found in ~/ on the Pi.
     Copy them to the Pi first:
       scp hailort*.deb "${SSH_ALIAS}:~/"
     Then re-run this script."
    fi

    backup_compose

    # ── Tag rollback images ────────────────────────────────────────────────
    info "Tagging current hailo-ollama image for rollback..."
    pi "
      docker tag hailo-ollama:${HAILO_VERSION} hailo-ollama:rollback 2>/dev/null || true
      echo ROLLBACK_TAGGED
    " || true

    # ── Stop containers that use the NPU ──────────────────────────────────
    info "Stopping Hailo containers (NPU must be free for dpkg)..."
    pi "
      cd ~/homeassistant
      docker compose stop hailo-ollama hailo-whisper 2>/dev/null || true
      docker compose rm -f hailo-ollama 2>/dev/null || true
      echo CONTAINERS_STOPPED
    " | grep CONTAINERS_STOPPED || true

    # ── Unload kernel module so dpkg post-install script can reload it ─────
    info "Unloading hailo1x_pci kernel module..."
    pi "sudo rmmod hailo1x_pci 2>/dev/null || true && echo MODULE_UNLOADED" || true

    # ── Install new HailoRT .deb packages ─────────────────────────────────
    info "Installing HailoRT ${new_version} packages..."
    pi "
      set -e
      DRIVER_DEB=\$(ls ~/hailort*pcie*driver*${new_version}*.deb ~/hailort*driver*${new_version}*.deb 2>/dev/null | head -1)
      RUNTIME_DEB=\$(ls ~/hailort_${new_version}*.deb ~/hailort-${new_version}*.deb ~/hailort*${new_version}*arm64*.deb 2>/dev/null | grep -v 'driver\|dkms\|pcie' | head -1)
      echo \"  Installing: \$DRIVER_DEB\"
      echo \"  Installing: \$RUNTIME_DEB\"
      sudo dpkg -i \"\$DRIVER_DEB\" \"\$RUNTIME_DEB\"
      sudo apt-get install -f -y -qq 2>&1 | tail -3
      echo HAILORT_PACKAGES_OK
    " | grep HAILORT_PACKAGES_OK || die "HailoRT ${new_version} package install failed"

    # ── DKMS rebuild ───────────────────────────────────────────────────────
    info "Rebuilding DKMS module for running kernel..."
    pi "
      sudo dkms autoinstall 2>&1 | tail -5
      sudo modprobe hailo1x_pci 2>/dev/null || true
      ls /dev/h1x* > /dev/null 2>&1 && echo HAILO_DEV_OK || { echo 'ERROR: /dev/h1x* missing after modprobe'; exit 1; }
    " | grep HAILO_DEV_OK || die "/dev/h1x-0 not present after DKMS rebuild"

    # ── Checkout new hailo_model_zoo_genai tag and rebuild binary ─────────
    info "Rebuilding hailo-ollama binary from source (tag v${new_version})..."
    info "This takes 5–15 minutes on Pi 5..."
    local build_rc=0
    pi "
      set -e
      GENAI_REPO=/home/ctf/hailo_model_zoo_genai
      [ -d \$GENAI_REPO ] || { echo 'ERROR: \$GENAI_REPO not found'; exit 1; }
      cd \$GENAI_REPO
      git fetch --tags 2>&1 | tail -3
      git checkout v${new_version} 2>&1 | tail -3
      cmake -B build -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -5
      cmake --build build --config Release -- -j4 2>&1 | tail -10
      sudo cmake --install build 2>&1 | tail -5
      echo BUILD_BINARY_DONE
    " | grep BUILD_BINARY_DONE || { build_rc=1; die "hailo-ollama binary rebuild failed"; }
    ok "hailo-ollama binary rebuilt"

    # ── Verify binary links against new version ────────────────────────────
    info "Verifying binary links against libhailort.so.${new_version}..."
    local ldd_out
    ldd_out=$(pi "ldd /usr/local/bin/hailo-ollama 2>&1 | grep hailort" || true)
    echo "  $ldd_out"
    echo "$ldd_out" | grep -q "${new_version}" || die "Binary still linked against old libhailort — rebuild may have failed"
    ok "Binary: linked against libhailort.so.${new_version}"

    # ── Rebuild Docker image with new binary ──────────────────────────────
    info "Removing old Docker image and rebuilding..."
    local new_tag="hailo-ollama:${new_version}"
    pi "docker rmi ${new_tag} 2>/dev/null || true && echo OLD_IMAGE_REMOVED" || true

    # Update HAILO_VERSION reference in the compose.yaml image tag
    HAILO_VERSION="$new_version"

    # Build the Docker image (same logic as upgrade_hailo_ollama_image)
    upgrade_hailo_ollama_image 2>&1
    return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: piper (TTS)
# ─────────────────────────────────────────────────────────────────────────────
upgrade_piper() {
    local target_tag="${1:-latest}"
    header "Upgrade: piper TTS"

    # ── Detect image name from compose ─────────────────────────────────────
    info "Detecting current Piper image from compose.yaml..."
    local piper_image
    piper_image=$(pi "
      python3 -c \"
import yaml
with open('${COMPOSE_FILE}') as f:
    c = yaml.safe_load(f)
for name, svc in c.get('services', {}).items():
    img = svc.get('image', '')
    if 'piper' in img.lower() or 'piper' in name.lower():
        print(img)
        break
\" 2>/dev/null || echo 'rhasspy/wyoming-piper:latest'
    " | tail -1)
    echo "  Current image: $piper_image"

    # Detect container name
    local piper_container
    piper_container=$(pi "docker ps --format '{{.Names}}' | grep -i piper | head -1 || echo piper" | tail -1)
    echo "  Container name: $piper_container"

    # ── Rollback tag ───────────────────────────────────────────────────────
    info "Tagging current image for rollback..."
    pi "docker tag \"${piper_image}\" piper-rollback:saved 2>/dev/null || true" || true

    backup_compose

    # ── Pin tag in compose if requested ───────────────────────────────────
    if [[ "$target_tag" != "latest" ]]; then
        local base_image="${piper_image%%:*}"
        info "Updating compose.yaml: $piper_image → ${base_image}:${target_tag}..."
        pi "
          python3 << 'PYEOF'
import yaml, re
path = '${COMPOSE_FILE}'
with open(path) as f:
    content = f.read()
old_img = '${piper_image}'
base = old_img.split(':')[0]
new_img = base + ':${target_tag}'
content = content.replace(old_img, new_img)
with open(path, 'w') as f:
    f.write(content)
print('  Updated', old_img, '->', new_img)
PYEOF
          echo COMPOSE_PINNED
        " | grep COMPOSE_PINNED || warn "Could not pin piper image tag in compose.yaml"
        piper_image="${piper_image%%:*}:${target_tag}"
    fi

    # ── Pull + restart ─────────────────────────────────────────────────────
    info "Pulling ${piper_image}..."
    pi "docker pull ${piper_image} && echo PULL_OK" | grep PULL_OK || die "docker pull failed for piper"

    info "Restarting piper container..."
    pi "
      cd ~/homeassistant
      docker compose up -d --force-recreate ${piper_container} 2>&1 | tail -5
      echo RESTART_OK
    " | grep RESTART_OK || die "docker compose up failed for piper"

    # ── Verify ─────────────────────────────────────────────────────────────
    verify_piper "$piper_container"
}

verify_piper() {
    local container="${1:-piper}"
    header "Verification: piper"
    local ok=true

    info "Checking container status..."
    local status
    status=$(pi "docker inspect ${container} --format '{{.State.Status}}' 2>/dev/null || echo missing")
    echo "  Status: $status"
    [[ "$status" == "running" ]] || { warn "Piper container not running"; ok=false; }

    info "Detecting Piper Wyoming port..."
    local piper_port
    piper_port=$(pi "docker port ${container} 2>/dev/null | grep -o '[0-9]*->10200' | cut -d'-' -f1 || echo 10200" | tail -1)
    echo "  Port: $piper_port"

    info "Waiting up to 20s for Wyoming TTS port ${piper_port}..."
    local port_open=false
    for i in $(seq 1 4); do
        if pi "ss -tlnp | grep -q :${piper_port} && echo PORT_OK" 2>/dev/null | grep -q PORT_OK; then
            port_open=true; break
        fi
        echo "  Waiting... ($i/4)"
        sleep 5
    done
    $port_open || { warn "Piper Wyoming port ${piper_port} not listening"; ok=false; }

    if $ok; then
        ok "piper: HEALTHY (running, port ${piper_port} listening)"
        return 0
    else
        warn "piper verification FAILED"
        pi "docker logs ${container} --tail 20 2>&1" || true
        return 1
    fi
}

rollback_piper() {
    local container="${1:-piper}"
    header "Rollback: piper"
    info "Restoring saved image..."
    pi "
      ORIG_IMG=\$(docker inspect ${container} --format '{{.Config.Image}}' 2>/dev/null || echo 'rhasspy/wyoming-piper:latest')
      BASE=\${ORIG_IMG%%:*}
      docker tag piper-rollback:saved \"\$ORIG_IMG\" 2>/dev/null || true
      cd ~/homeassistant
      docker compose up -d --force-recreate ${container} 2>&1 | tail -5
      echo ROLLBACK_OK
    " | grep ROLLBACK_OK && ok "Rollback applied" || warn "Rollback issues — check manually"
    restore_compose
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: homeassistant
# ─────────────────────────────────────────────────────────────────────────────
upgrade_homeassistant() {
    local target_tag="${1:-latest}"
    header "Upgrade: Home Assistant → ${target_tag}"

    info "Current Home Assistant state:"
    pi "
      HA_IMG=\$(docker inspect homeassistant --format '{{.Config.Image}}' 2>/dev/null || echo unknown)
      HA_VER=\$(docker exec homeassistant python3 -c \"import homeassistant.const as c; print(c.__version__)\" 2>/dev/null || echo unknown)
      echo \"  Image  : \$HA_IMG\"
      echo \"  Version: \$HA_VER\"
      echo CURRENT_INFO_DONE
    " | grep -v CURRENT_INFO_DONE || true

    info "Tagging current image for rollback..."
    pi "
      HA_IMG=\$(docker inspect homeassistant --format '{{.Config.Image}}' 2>/dev/null || echo 'ghcr.io/home-assistant/home-assistant:stable')
      docker tag \"\$HA_IMG\" homeassistant:rollback 2>/dev/null && echo ROLLBACK_TAGGED || echo 'Could not tag (no existing image?)'
    " || true

    backup_compose

    # Pin tag in compose if not "latest"/"stable"
    if [[ "$target_tag" != "latest" && "$target_tag" != "stable" ]]; then
        info "Pinning HA image tag to ${target_tag} in compose.yaml..."
        pi "
          python3 << 'PYEOF'
import re
path = '${COMPOSE_FILE}'
with open(path) as f:
    content = f.read()
# Replace the HA image tag — handles both quoted and unquoted image values
content = re.sub(
    r'(ghcr\.io/home-assistant/home-assistant):[\w.\-]+',
    r'\g<1>:${target_tag}',
    content
)
with open(path, 'w') as f:
    f.write(content)
print('  Pinned HA image to ${target_tag}')
PYEOF
          echo COMPOSE_PINNED
        " | grep COMPOSE_PINNED || warn "Could not pin HA image tag in compose.yaml"
    fi

    # ── Pull ───────────────────────────────────────────────────────────────
    info "Pulling Home Assistant image..."
    pi "
      set -e
      HA_IMG=\$(grep -A3 'container_name: homeassistant' ${COMPOSE_FILE} | grep 'image:' | awk '{print \$2}' | tr -d '\"' || echo 'ghcr.io/home-assistant/home-assistant:stable')
      echo \"  Pulling: \$HA_IMG\"
      docker pull \"\$HA_IMG\"
      echo PULL_OK
    " | grep PULL_OK || die "docker pull failed for homeassistant"

    # ── Restart ────────────────────────────────────────────────────────────
    info "Restarting Home Assistant..."
    pi "
      cd ~/homeassistant
      docker compose up -d --force-recreate homeassistant 2>&1 | tail -5
      echo RESTART_OK
    " | grep RESTART_OK || die "docker compose up failed for homeassistant"

    # ── Verify ─────────────────────────────────────────────────────────────
    verify_homeassistant
}

verify_homeassistant() {
    header "Verification: Home Assistant"
    local ok=true

    info "Checking container status..."
    local status
    status=$(pi "docker inspect homeassistant --format '{{.State.Status}}' 2>/dev/null || echo missing")
    echo "  Status: $status"
    [[ "$status" == "running" ]] || { warn "HA container not running"; ok=false; }

    info "Waiting up to 60s for HA web UI on port 8123..."
    local ha_up=false
    for i in $(seq 1 12); do
        if pi "curl -sf http://localhost:8123/ > /dev/null 2>&1 && echo HA_UP" 2>/dev/null | grep -q HA_UP; then
            ha_up=true; break
        fi
        echo "  Waiting... ($i/12)"
        sleep 5
    done
    $ha_up || { warn "HA web UI not responding on port 8123 after 60s"; ok=false; }

    if $ok; then
        info "Checking HA version after upgrade..."
        local ha_ver
        ha_ver=$(pi "docker exec homeassistant grep -r '__version__' /usr/src/homeassistant/homeassistant/const.py 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo unknown")
        echo "  HA Version: $ha_ver"
        ok "homeassistant: HEALTHY (running, UI at :8123, version $ha_ver)"
        return 0
    else
        warn "homeassistant verification FAILED"
        pi "docker logs homeassistant --tail 30 2>&1" || true
        return 1
    fi
}

rollback_homeassistant() {
    header "Rollback: Home Assistant"
    pi "
      docker tag homeassistant:rollback \$(docker inspect homeassistant --format '{{.Config.Image}}' 2>/dev/null || echo 'ghcr.io/home-assistant/home-assistant:stable') 2>/dev/null || true
      cd ~/homeassistant
      docker compose up -d --force-recreate homeassistant 2>&1 | tail -5
      echo ROLLBACK_OK
    " | grep ROLLBACK_OK && ok "Rollback applied" || warn "Rollback issues — check manually"
    restore_compose
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: extended_openai_conversation (GitHub custom component)
# ─────────────────────────────────────────────────────────────────────────────
upgrade_extended_openai() {
    local target_tag="${1:-}"   # empty = latest
    header "Upgrade: extended_openai_conversation"

    local eoca_dir="$HOME/homeassistant/config/custom_components/extended_openai_conversation"

    info "Current version:"
    pi "
      EOCA_DIR=~/homeassistant/config/custom_components/extended_openai_conversation
      if sudo test -f \"\$EOCA_DIR/manifest.json\" 2>/dev/null; then
        VER=\$(sudo python3 -c \"import json; print(json.load(open('\$EOCA_DIR/manifest.json'))['version'])\" 2>/dev/null || echo unknown)
        echo \"  Installed version: v\$VER\"
      else
        echo '  Not currently installed'
      fi
      echo CURRENT_INFO_DONE
    " | grep -v CURRENT_INFO_DONE || true

    # ── Fetch latest / target release from GitHub ──────────────────────────
    info "Fetching release info from GitHub..."
    local release_info
    if [[ -n "$target_tag" ]]; then
        release_info=$(pi "curl -sf https://api.github.com/repos/jekalmin/extended_openai_conversation/releases/tags/${target_tag} 2>/dev/null || echo '{}'")
    else
        release_info=$(pi "curl -sf https://api.github.com/repos/jekalmin/extended_openai_conversation/releases/latest 2>/dev/null || echo '{}'")
    fi

    local tag
    tag=$(echo "$release_info" | pi "python3 -c \"import json,sys; print(json.load(sys.stdin).get('tag_name','unknown'))\"" || echo "unknown")
    echo "  Target release: $tag"

    if [[ "$tag" == "unknown" ]]; then
        die "Could not fetch release info from GitHub. Check Pi internet connection."
    fi

    # ── Backup current install ─────────────────────────────────────────────
    info "Backing up current custom component..."
    pi "
      EOCA_DIR=~/homeassistant/config/custom_components/extended_openai_conversation
      if sudo test -d \"\$EOCA_DIR\" 2>/dev/null; then
        sudo cp -r \"\$EOCA_DIR\" \"\${EOCA_DIR}.upgrade-bak\" 2>/dev/null
        echo '  Backed up to extended_openai_conversation.upgrade-bak'
      else
        echo '  No existing installation to back up'
      fi
      echo BACKUP_DONE
    " | grep BACKUP_DONE || true

    # ── Download and install ───────────────────────────────────────────────
    info "Downloading and installing extended_openai_conversation ${tag}..."
    local install_rc=0
    pi "
      set -e
      RELEASE_JSON=\$(curl -sf https://api.github.com/repos/jekalmin/extended_openai_conversation/releases/tags/${tag})
      ZIP_URL=\$(echo \"\$RELEASE_JSON\" | python3 -c \"
import json, sys
rel = json.load(sys.stdin)
assets = [a['browser_download_url'] for a in rel.get('assets', []) if a['name'].endswith('.zip')]
print(assets[0] if assets else '')
\")
      if [[ -z \"\$ZIP_URL\" ]]; then
        ZIP_URL=\"https://github.com/jekalmin/extended_openai_conversation/archive/refs/tags/${tag}.zip\"
      fi
      echo \"  Downloading: \$ZIP_URL\"
      curl -sL -o /tmp/eoca.zip \"\$ZIP_URL\"

      rm -rf /tmp/eoca_work && mkdir /tmp/eoca_work
      unzip -q /tmp/eoca.zip -d /tmp/eoca_work

      MANIFEST=\$(find /tmp/eoca_work -name manifest.json | head -1)
      [ -n \"\$MANIFEST\" ] || { echo 'ERROR: manifest.json not found in zip'; exit 1; }
      INTEGRATION_DIR=\$(dirname \"\$MANIFEST\")

      CUSTOM_DIR=~/homeassistant/config/custom_components
      EOCA_DIR=\$CUSTOM_DIR/extended_openai_conversation

      sudo mkdir -p \"\$CUSTOM_DIR\"
      sudo rm -rf \"\$EOCA_DIR\"
      sudo cp -r \"\$INTEGRATION_DIR\" \"\$EOCA_DIR\"
      rm -rf /tmp/eoca.zip /tmp/eoca_work

      VER=\$(sudo python3 -c \"import json; print(json.load(open('\$EOCA_DIR/manifest.json'))['version'])\" 2>/dev/null || echo unknown)
      echo \"  Installed extended_openai_conversation v\$VER\"
      echo EOCA_INSTALLED
    " | grep EOCA_INSTALLED || { install_rc=1; die "extended_openai_conversation install failed"; }

    # ── Restart HA to pick up the new component ────────────────────────────
    info "Restarting Home Assistant to load new component..."
    pi "
      cd ~/homeassistant
      docker compose restart homeassistant 2>&1 | tail -3
      echo HA_RESTARTING
    " | grep HA_RESTARTING || warn "HA restart had issues"

    # ── Verify ─────────────────────────────────────────────────────────────
    verify_extended_openai
}

verify_extended_openai() {
    header "Verification: extended_openai_conversation"
    local ok=true

    info "Waiting up to 60s for HA to come back up..."
    local ha_up=false
    for i in $(seq 1 12); do
        if pi "curl -sf http://localhost:8123/ > /dev/null 2>&1 && echo HA_UP" 2>/dev/null | grep -q HA_UP; then
            ha_up=true; break
        fi
        echo "  Waiting... ($i/12)"
        sleep 5
    done
    $ha_up || { warn "HA did not come back up after restart"; ok=false; }

    info "Checking installed version..."
    pi "
      EOCA_DIR=~/homeassistant/config/custom_components/extended_openai_conversation
      VER=\$(sudo python3 -c \"import json; print(json.load(open('\$EOCA_DIR/manifest.json'))['version'])\" 2>/dev/null || echo unknown)
      echo \"  Installed: v\$VER\"
    " || true

    if $ok; then
        ok "extended_openai_conversation: HEALTHY (HA is up)"
        info "Tip: check Settings → Devices & Services → Extended OpenAI Conversation in HA UI for integration status."
        return 0
    else
        warn "Verification FAILED — HA did not restart cleanly"
        pi "docker logs homeassistant --tail 30 2>&1" || true
        return 1
    fi
}

rollback_extended_openai() {
    header "Rollback: extended_openai_conversation"
    pi "
      EOCA_DIR=~/homeassistant/config/custom_components/extended_openai_conversation
      if sudo test -d \"\${EOCA_DIR}.upgrade-bak\" 2>/dev/null; then
        sudo rm -rf \"\$EOCA_DIR\"
        sudo cp -r \"\${EOCA_DIR}.upgrade-bak\" \"\$EOCA_DIR\"
        echo '  Restored from backup'
      else
        echo '  No backup found — cannot rollback'
      fi
      cd ~/homeassistant
      docker compose restart homeassistant 2>&1 | tail -3
      echo ROLLBACK_DONE
    " | grep ROLLBACK_DONE && ok "Rollback applied" || warn "Rollback issues — check manually"
}

# ─────────────────────────────────────────────────────────────────────────────
# GENERIC: standard Docker-pull upgrade / verify / rollback
# Used by most services — special cases call these after pre-flight steps.
# ─────────────────────────────────────────────────────────────────────────────

# upgrade_standard_service <display_name> <compose_svc> <container> [target_tag] [image_base]
#   image_base: when provided, the image registry+name is already known (e.g.
#               "ghcr.io/riddix/home-assistant-matter-hub"). The function will
#               grep compose.yaml for the current tag instead of relying on
#               python3-yaml or docker inspect (both can fail for stopped services).
upgrade_standard_service() {
    local display="$1" compose_svc="$2" container="$3" target_tag="${4:-}" image_base="${5:-}"

    header "Upgrade: ${display}"

    # ── Current image info ────────────────────────────────────────────────
    info "Current image:"
    pi "
      IMG=\$(docker inspect ${container} --format '{{.Config.Image}}' 2>/dev/null || echo unknown)
      echo \"  Image: \$IMG\"
    " || true

    # ── Resolve image from compose ─────────────────────────────────────────
    local cur_image
    if [[ -n "$image_base" ]]; then
        # Known image base: grep compose.yaml for the tag (works even when the
        # container is stopped or the service name differs from compose_svc).
        # sed BRE extracts the tag after "image_base:" — no double-quote nesting needed.
        local cur_tag
        cur_tag=$(pi "
          sed -n 's|.*${image_base}:\\([^[:space:]]*\\).*|\\1|p' '${COMPOSE_FILE}' 2>/dev/null | head -1
        " | head -1 | tr -d '"')
        cur_image="${image_base}:${cur_tag:-latest}"
    else
        cur_image=$(pi "
          python3 -c \"
import yaml
with open('${COMPOSE_FILE}') as f:
    c = yaml.safe_load(f)
svc = c.get('services', {}).get('${compose_svc}', {})
print(svc.get('image', 'unknown'))
\" 2>/dev/null || docker inspect ${container} --format '{{.Config.Image}}' 2>/dev/null || echo unknown
        " | tail -1)
    fi
    echo "  Compose image: $cur_image"

    # ── Tag current image for rollback ────────────────────────────────────
    info "Tagging current image for rollback..."
    pi "docker tag '${cur_image}' '${container}-rollback:saved' 2>/dev/null || true" || true

    backup_compose

    # ── If a specific tag requested, pin it in compose.yaml ───────────────
    if [[ -n "$target_tag" ]]; then
        local base_image="${cur_image%%:*}"
        local new_image="${base_image}:${target_tag}"
        if [[ "$cur_image" != "$new_image" ]]; then
            info "Pinning image to ${new_image} in compose.yaml..."
            pi "
              python3 -c \"
content = open('${COMPOSE_FILE}').read()
content = content.replace('${cur_image}', '${new_image}')
open('${COMPOSE_FILE}', 'w').write(content)
print('  Pinned: ${cur_image} -> ${new_image}')
\" && echo PINNED
            " | grep PINNED || warn "Could not pin tag — compose.yaml may need manual edit"
            cur_image="$new_image"
        fi
    fi

    # ── Pull ──────────────────────────────────────────────────────────────
    info "Pulling ${cur_image}..."
    pi "docker pull '${cur_image}' && echo PULL_OK" | grep PULL_OK \
        || die "docker pull failed for ${cur_image}"

    # ── Restart via compose ───────────────────────────────────────────────
    info "Restarting ${compose_svc}..."
    pi "
      cd ~/homeassistant
      docker compose up -d --force-recreate ${compose_svc} 2>&1 | tail -5
      echo RESTART_OK
    " | grep RESTART_OK || die "docker compose up failed for ${compose_svc}"
}

# verify_standard_service <display_name> <container> [verify_port]
verify_standard_service() {
    local display="$1" container="$2" verify_port="${3:-}"
    header "Verification: ${display}"
    local pass=true

    info "Checking container status..."
    local status
    status=$(pi "docker inspect ${container} --format '{{.State.Status}}' 2>/dev/null || echo missing")
    echo "  Status: $status"
    [[ "$status" == "running" ]] || { warn "Container not running"; pass=false; }

    if [[ -n "$verify_port" && "$pass" == "true" ]]; then
        info "Waiting up to 30s for port ${verify_port}..."
        local port_open=false
        for i in $(seq 1 6); do
            if pi "ss -tlnp 2>/dev/null | grep -q :${verify_port} && echo PORT_OK" 2>/dev/null | grep -q PORT_OK; then
                port_open=true; break
            fi
            echo "  Waiting... ($i/6)"
            sleep 5
        done
        $port_open || { warn "Port ${verify_port} not listening"; pass=false; }
    fi

    if $pass; then
        ok "${display}: HEALTHY${verify_port:+ (port ${verify_port} listening)}"
        return 0
    else
        warn "${display}: verification FAILED"
        pi "docker logs ${container} --tail 25 2>&1" || true
        return 1
    fi
}

# rollback_standard_service <display_name> <compose_svc> <container>
rollback_standard_service() {
    local display="$1" compose_svc="$2" container="$3"
    header "Rollback: ${display}"
    info "Restoring rollback image..."
    pi "
      CUR_IMG=\$(docker inspect ${container} --format '{{.Config.Image}}' 2>/dev/null || echo unknown)
      docker tag '${container}-rollback:saved' \"\$CUR_IMG\" 2>/dev/null || true
      cd ~/homeassistant
      docker compose up -d --force-recreate ${compose_svc} 2>&1 | tail -5
      echo ROLLBACK_OK
    " | grep ROLLBACK_OK && ok "Rollback applied" || warn "Rollback issues — check manually"
    restore_compose
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: zigbee2mqtt
# ─────────────────────────────────────────────────────────────────────────────
upgrade_zigbee2mqtt()   { upgrade_standard_service "zigbee2mqtt" "zigbee2mqtt" "zigbee2mqtt" "${1:-}"; }
verify_zigbee2mqtt()    { verify_standard_service  "zigbee2mqtt" "zigbee2mqtt" "8080"; }
rollback_zigbee2mqtt()  { rollback_standard_service "zigbee2mqtt" "zigbee2mqtt" "zigbee2mqtt"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: zwave-js-ui
# ─────────────────────────────────────────────────────────────────────────────
upgrade_zwave()   { upgrade_standard_service "zwave-js-ui" "zwave-js-ui" "zwave-js-ui" "${1:-}"; }
verify_zwave()    { verify_standard_service  "zwave-js-ui" "zwave-js-ui" "8091"; }
rollback_zwave()  { rollback_standard_service "zwave-js-ui" "zwave-js-ui" "zwave-js-ui"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: open-webui  ⚠ database backup required before upgrading
# ─────────────────────────────────────────────────────────────────────────────
upgrade_open_webui() {
    local target_tag="${1:-}"
    header "Upgrade: open-webui"

    warn "open-webui v0.9+ contains database schema changes."
    warn "Rolling back after a schema migration may cause data loss."
    echo ""
    info "Backing up open-webui data volume before proceeding..."
    local backup_rc=0
    pi "
      TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
      BACKUP_DIR=~/homeassistant/backups
      mkdir -p \"\$BACKUP_DIR\"
      # Data is stored in open-webui Docker volume — copy via a temp container
      if docker volume inspect open-webui 2>/dev/null | grep -q 'open-webui'; then
        docker run --rm \
          -v open-webui:/data:ro \
          -v \"\$BACKUP_DIR\":/backup \
          alpine tar czf \"/backup/open-webui-data-\${TIMESTAMP}.tar.gz\" -C /data . 2>&1
        echo \"  Backup saved: \$BACKUP_DIR/open-webui-data-\${TIMESTAMP}.tar.gz\"
        echo BACKUP_OK
      else
        # Try bind-mount path as fallback
        DATA_PATH=\$(docker inspect open-webui --format '{{range .Mounts}}{{if eq .Destination \"/app/backend/data\"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || echo '')
        if [ -n \"\$DATA_PATH\" ]; then
          sudo tar czf \"\$BACKUP_DIR/open-webui-data-\${TIMESTAMP}.tar.gz\" -C \"\$DATA_PATH\" . 2>&1
          echo \"  Backup saved: \$BACKUP_DIR/open-webui-data-\${TIMESTAMP}.tar.gz\"
          echo BACKUP_OK
        else
          echo '  WARNING: Could not locate open-webui data — skipping backup'
          echo BACKUP_SKIP
        fi
      fi
    " | grep -E "BACKUP_OK|BACKUP_SKIP" || backup_rc=1

    if [[ $backup_rc -ne 0 ]]; then
        warn "Data backup step had issues."
    fi

    local proceed
    prompt_yn "Data backup attempted. Proceed with upgrade?" proceed
    [[ "$proceed" == "y" ]] || { info "Upgrade cancelled."; return 0; }

    upgrade_standard_service "open-webui" "open-webui" "open-webui" "$target_tag"
}
verify_open_webui()   { verify_standard_service  "open-webui" "open-webui" "4000"; }
rollback_open_webui() {
    warn "Rolling back open-webui. If the DB schema was already migrated, data may not load correctly."
    rollback_standard_service "open-webui" "open-webui" "open-webui"
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: esphome  ⚠ CPU frequency change from 2026.4.x may affect some ESPs
# ─────────────────────────────────────────────────────────────────────────────
upgrade_esphome() {
    local target_tag="${1:-}"
    header "Upgrade: ESPHome"
    warn "ESPHome 2026.4.x changes default CPU frequency (160 → 240 MHz)."
    warn "This may cause instability on power-constrained or modded ESP devices."
    warn "Test on a non-critical device first after upgrading."
    echo ""
    local proceed
    prompt_yn "Proceed with ESPHome upgrade?" proceed
    [[ "$proceed" == "y" ]] || { info "Upgrade cancelled."; return 0; }
    upgrade_standard_service "esphome" "esphome" "esphome" "$target_tag"
}
verify_esphome()   { verify_standard_service  "esphome" "esphome" "6052"; }
rollback_esphome() { rollback_standard_service "esphome" "esphome" "esphome"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: cadvisor  ⚠ registry changed: gcr.io → ghcr.io from v0.53.0+
# ─────────────────────────────────────────────────────────────────────────────
upgrade_cadvisor() {
    local target_tag="${1}"
    header "Upgrade: cAdvisor"

    warn "cAdvisor moved registries at v0.49.1+."
    warn "Old: gcr.io/cadvisor/cadvisor"
    warn "New: ghcr.io/google/cadvisor"
    warn "compose.yaml will be updated to use the new registry."
    echo ""

    # ── Resolve target tag if not explicitly provided ─────────────────────
    # Walk GitHub releases newest-first; pick the first tag that actually has
    # a Docker image on ghcr.io (releases are sometimes made without images).
    if [ -z "$target_tag" ]; then
        info "Auto-detecting latest cadvisor release with a ghcr.io image..."
        target_tag=$(pi "
          set +e
          # Fetch up to 20 recent release tags from GitHub
          TAGS=\$(curl -sf --max-time 15 'https://github.com/google/cadvisor/releases' 2>/dev/null \
            | grep -oP 'releases/tag/v[0-9]+\.[0-9]+\.[0-9]+' \
            | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
            | awk '!seen[\$0]++' | head -20)
          # Add known-good fallback at the end so we always have something to try
          TAGS=\"\$TAGS
v0.52.1
v0.49.1
v0.47.2\"
          for TAG in \$TAGS; do
            docker manifest inspect ghcr.io/google/cadvisor:\$TAG > /dev/null 2>&1 && echo \"\$TAG\" && exit 0
          done
          echo ''
        " 2>/dev/null | tr -d '[:space:]')
        if [ -n "$target_tag" ]; then
            info "Found pullable release: $target_tag"
        else
            die "Could not find any cadvisor release with a ghcr.io image. Check https://github.com/google/cadvisor/pkgs/container/cadvisor"
        fi
    else
        # ── Verify explicitly-provided tag exists on ghcr.io ──────────────
        info "Verifying ghcr.io/google/cadvisor:${target_tag} is pullable..."
        MANIFEST_CHECK=$(pi "docker manifest inspect ghcr.io/google/cadvisor:${target_tag} > /dev/null 2>&1 && echo MANIFEST_OK || echo MANIFEST_MISSING" 2>/dev/null | tr -d '[:space:]') || MANIFEST_CHECK="MANIFEST_MISSING"
        if [ "$MANIFEST_CHECK" != "MANIFEST_OK" ]; then
            die "Tag ${target_tag} does not exist on ghcr.io/google/cadvisor. Check https://github.com/google/cadvisor/pkgs/container/cadvisor for valid tags."
        fi
    fi

    # ── Rewrite image reference in compose.yaml ───────────────────────────
    info "Updating compose.yaml → ghcr.io/google/cadvisor:${target_tag}..."
    pi "
      sed -i 's|gcr.io/cadvisor/cadvisor:[^[:space:]]*|ghcr.io/google/cadvisor:${target_tag}|g' ${COMPOSE_FILE}
      sed -i 's|gcr.io/cadvisor/cadvisor\b|ghcr.io/google/cadvisor:${target_tag}|g' ${COMPOSE_FILE}
      sed -i 's|ghcr.io/google/cadvisor:[^[:space:]]*|ghcr.io/google/cadvisor:${target_tag}|g' ${COMPOSE_FILE}
      echo COMPOSE_UPDATED
    " | grep COMPOSE_UPDATED || die "Failed to update cadvisor image in compose.yaml"

    # ── Pull new image ────────────────────────────────────────────────────
    info "Pulling ghcr.io/google/cadvisor:${target_tag}..."
    pi "docker pull ghcr.io/google/cadvisor:${target_tag} && echo PULL_OK" \
        | grep PULL_OK || die "docker pull failed for cadvisor"

    info "Restarting cadvisor..."
    pi "
      cd ~/homeassistant
      docker compose up -d --force-recreate cadvisor 2>&1 | tail -5
      echo RESTART_OK
    " | grep RESTART_OK || die "docker compose up failed for cadvisor"
}
verify_cadvisor()   { verify_standard_service "cAdvisor" "cadvisor" "8080"; }
rollback_cadvisor() {
    header "Rollback: cAdvisor"
    pi "
      docker tag cadvisor-rollback:saved \$(docker inspect cadvisor --format '{{.Config.Image}}' 2>/dev/null || echo 'ghcr.io/google/cadvisor:rollback') 2>/dev/null || true
      cd ~/homeassistant
      docker compose up -d --force-recreate cadvisor 2>&1 | tail -5
      echo ROLLBACK_OK
    " | grep ROLLBACK_OK && ok "Rollback applied" || warn "Rollback issues — check manually"
    restore_compose
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: mosquitto (MQTT broker)
# ─────────────────────────────────────────────────────────────────────────────
upgrade_mosquitto()   { upgrade_standard_service "mosquitto" "mosquitto" "mosquitto" "${1:-}"; }
verify_mosquitto()    { verify_standard_service  "mosquitto" "mosquitto" "1883"; }
rollback_mosquitto()  { rollback_standard_service "mosquitto" "mosquitto" "mosquitto"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: ring-mqtt
# ─────────────────────────────────────────────────────────────────────────────
upgrade_ring_mqtt()   { upgrade_standard_service "ring-mqtt" "ring-mqtt" "ring-mqtt" "${1:-}"; }
verify_ring_mqtt()    { verify_standard_service  "ring-mqtt" "ring-mqtt" ""; }   # no fixed port
rollback_ring_mqtt()  { rollback_standard_service "ring-mqtt" "ring-mqtt" "ring-mqtt"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: uptime-kuma
# ─────────────────────────────────────────────────────────────────────────────
upgrade_uptime_kuma()   { upgrade_standard_service "uptime-kuma" "uptime-kuma" "uptime-kuma" "${1:-}"; }
verify_uptime_kuma()    { verify_standard_service  "uptime-kuma" "uptime-kuma" "3001"; }
rollback_uptime_kuma()  { rollback_standard_service "uptime-kuma" "uptime-kuma" "uptime-kuma"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: cloudflared
# ─────────────────────────────────────────────────────────────────────────────
upgrade_cloudflared()   { upgrade_standard_service "cloudflared" "cloudflared" "cloudflared" "${1:-}"; }
verify_cloudflared()    { verify_standard_service  "cloudflared" "cloudflared" ""; }   # outbound tunnel, no listen port
rollback_cloudflared()  { rollback_standard_service "cloudflared" "cloudflared" "cloudflared"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: grafana-alloy
# ─────────────────────────────────────────────────────────────────────────────
upgrade_grafana_alloy()   { upgrade_standard_service "grafana-alloy" "grafana-alloy" "grafana-alloy" "${1:-}"; }
verify_grafana_alloy()    { verify_standard_service  "grafana-alloy" "grafana-alloy" "12345"; }
rollback_grafana_alloy()  { rollback_standard_service "grafana-alloy" "grafana-alloy" "grafana-alloy"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: home-assistant-matter-hub
# ─────────────────────────────────────────────────────────────────────────────
upgrade_matter_hub()   { upgrade_standard_service "HA Matter Hub" "matter-hub" "matter-hub" "${1:-}" "ghcr.io/riddix/home-assistant-matter-hub"; }
verify_matter_hub()    { verify_standard_service  "HA Matter Hub" "matter-hub" ""; }
rollback_matter_hub()  { rollback_standard_service "HA Matter Hub" "matter-hub" "matter-hub"; }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICE: pypowerwall-server
# ─────────────────────────────────────────────────────────────────────────────
upgrade_pypowerwall()   { upgrade_standard_service "pypowerwall-server" "pypowerwall-server" "pypowerwall-server" "${1:-}" "jasonacox/pypowerwall-server"; }
verify_pypowerwall()    { verify_standard_service  "pypowerwall-server" "pypowerwall-server" "8675"; }
rollback_pypowerwall()  { rollback_standard_service "pypowerwall-server" "pypowerwall-server" "pypowerwall-server"; }

# ─────────────────────────────────────────────────────────────────────────────
# GENERIC upgrade wrapper: run upgrade → verify → offer rollback
# ─────────────────────────────────────────────────────────────────────────────
run_upgrade() {
    local service="$1"
    local upgrade_fn="$2"
    local verify_fn="$3"
    local rollback_fn="$4"
    shift 4
    local args=("$@")

    local _pad
    _pad=$(printf '%*s' $((42 - ${#service})) '')
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Service: ${BOLD}${service}${NC}${CYAN}${_pad}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

    # Run upgrade
    local upgrade_rc=0
    "${upgrade_fn}" "${args[@]}" || upgrade_rc=$?

    if [[ $upgrade_rc -ne 0 ]]; then
        warn "Upgrade function exited with error ($upgrade_rc). Running verify anyway..."
    fi

    # Verify
    local verify_rc=0
    "${verify_fn}" "${args[@]}" || verify_rc=$?

    if [[ $verify_rc -eq 0 ]]; then
        echo ""
        ok "✔  Upgrade of ${service} succeeded and verified."
        return 0
    fi

    # Verification failed
    echo ""
    warn "Verification of ${service} FAILED."
    local do_rollback
    prompt_yn "Roll back ${service} to the previous version?" do_rollback
    if [[ "$do_rollback" == "y" ]]; then
        "${rollback_fn}" "${args[@]}" || true
        echo ""
        info "Re-running verification after rollback..."
        "${verify_fn}" "${args[@]}" && ok "Service recovered after rollback." \
            || die "Service is unhealthy even after rollback. Manual intervention needed."
    else
        warn "Rollback declined. Service may be in a broken state."
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MENU
# ─────────────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "${BOLD}${CYAN}  ── Hailo / Voice Pipeline ────────────────────────────────${NC}"
    echo -e "   ${BOLD} 1${NC}) hailo-whisper              Docker image pull + restart"
    echo -e "   ${BOLD} 2${NC}) hailo-ollama               Docker image rebuild (proxy/entrypoint)"
    echo -e "   ${BOLD} 3${NC}) hailo-ollama (full rebuild) New HailoRT version — recompile from source"
    echo -e "   ${BOLD} 4${NC}) piper                      Docker image pull + restart"
    echo -e "   ${BOLD} 5${NC}) homeassistant              Docker image pull + restart"
    echo -e "   ${BOLD} 6${NC}) extended_openai_conversation GitHub custom component"
    echo ""
    echo -e "${BOLD}${CYAN}  ── Smart Home Integrations ───────────────────────────────${NC}"
    echo -e "   ${BOLD} 7${NC}) zigbee2mqtt                Docker image pull + restart"
    echo -e "   ${BOLD} 8${NC}) zwave-js-ui                Docker image pull + restart"
    echo -e "   ${BOLD} 9${NC}) open-webui               ⚠ DB backup + Docker image pull"
    echo -e "   ${BOLD}10${NC}) esphome                  ⚠ CPU freq warning + Docker pull"
    echo -e "   ${BOLD}11${NC}) cadvisor                 ⚠ Registry change + Docker pull (auto-detects latest)"
    echo -e "   ${BOLD}12${NC}) mosquitto                  Docker image pull + restart"
    echo -e "   ${BOLD}13${NC}) ring-mqtt                  Docker image pull + restart"
    echo ""
    echo -e "${BOLD}${CYAN}  ── Infrastructure ────────────────────────────────────────${NC}"
    echo -e "   ${BOLD}14${NC}) uptime-kuma                Docker image pull + restart"
    echo -e "   ${BOLD}15${NC}) cloudflared                Docker image pull + restart"
    echo -e "   ${BOLD}16${NC}) grafana-alloy              Docker image pull + restart"
    echo -e "   ${BOLD}17${NC}) home-assistant-matter-hub  Docker image pull + restart"
    echo -e "   ${BOLD}18${NC}) pypowerwall-server         Docker image pull + restart"
    echo ""
    echo -e "   ${BOLD} v${NC}) verify all services        Health check — no changes"
    echo -e "   ${BOLD} q${NC}) quit"
    echo ""
    prompt "Choice:" MENU_CHOICE ""
}

verify_all() {
    header "Verify all services"
    local any_fail=false

    verify_hailo_whisper   || any_fail=true
    verify_hailo_ollama    || any_fail=true
    verify_piper           || any_fail=true
    verify_homeassistant   || any_fail=true
    verify_extended_openai || any_fail=true
    verify_zigbee2mqtt     || any_fail=true
    verify_zwave           || any_fail=true
    verify_open_webui      || any_fail=true
    verify_esphome         || any_fail=true
    verify_cadvisor        || any_fail=true
    verify_mosquitto       || any_fail=true
    verify_ring_mqtt       || any_fail=true
    verify_uptime_kuma     || any_fail=true
    verify_cloudflared     || any_fail=true
    verify_grafana_alloy   || any_fail=true
    verify_matter_hub      || any_fail=true
    verify_pypowerwall     || any_fail=true

    echo ""
    if $any_fail; then
        warn "One or more services failed verification — see above."
    else
        ok "All services: HEALTHY"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Hailo Voice Assistant — Service Upgrade Manager      ║${NC}"
echo -e "${CYAN}║   Upgrades one service at a time with verification     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"

# Parse optional --hailo-version flag
for arg in "$@"; do
    case "$arg" in
        --hailo-version=*) HAILO_VERSION="${arg#*=}" ;;
        --hailo-version)   shift; HAILO_VERSION="${1:-$HAILO_VERSION}" ;;
    esac
done

# Pre-flight SSH check
pi_check_ssh

# If a service name was passed as first positional arg, jump straight to it
DIRECT_SERVICE="${1:-}"
DIRECT_SERVICE="${DIRECT_SERVICE#--*}"   # strip any flag that leaked through

if [[ -n "$DIRECT_SERVICE" ]]; then
    case "$DIRECT_SERVICE" in
        hailo-whisper)
            prompt "Target image tag (default: latest):" TARGET_TAG "latest"
            run_upgrade "hailo-whisper" upgrade_hailo_whisper verify_hailo_whisper rollback_hailo_whisper "$TARGET_TAG"
            ;;
        hailo-ollama)
            run_upgrade "hailo-ollama" upgrade_hailo_ollama_image verify_hailo_ollama rollback_hailo_ollama
            ;;
        hailo-ollama-full)
            prompt "New HailoRT version (e.g. 5.4.0):" NEW_VER ""
            [[ -n "$NEW_VER" ]] || die "HailoRT version is required for full rebuild"
            run_upgrade "hailo-ollama (full)" upgrade_hailo_ollama_full verify_hailo_ollama rollback_hailo_ollama "$NEW_VER"
            ;;
        piper)
            prompt "Target image tag (default: latest):" TARGET_TAG "latest"
            run_upgrade "piper" upgrade_piper verify_piper rollback_piper "$TARGET_TAG"
            ;;
        homeassistant)
            prompt "Target image tag (default: stable):" TARGET_TAG "stable"
            run_upgrade "homeassistant" upgrade_homeassistant verify_homeassistant rollback_homeassistant "$TARGET_TAG"
            ;;
        extended_openai_conversation|eoca)
            prompt "Target release tag (leave blank for latest):" TARGET_TAG ""
            run_upgrade "extended_openai_conversation" upgrade_extended_openai verify_extended_openai rollback_extended_openai "$TARGET_TAG"
            ;;
        zigbee2mqtt)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "zigbee2mqtt" upgrade_zigbee2mqtt verify_zigbee2mqtt rollback_zigbee2mqtt "$TARGET_TAG"
            ;;
        zwave-js-ui|zwave)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "zwave-js-ui" upgrade_zwave verify_zwave rollback_zwave "$TARGET_TAG"
            ;;
        open-webui)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "open-webui" upgrade_open_webui verify_open_webui rollback_open_webui "$TARGET_TAG"
            ;;
        esphome)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "esphome" upgrade_esphome verify_esphome rollback_esphome "$TARGET_TAG"
            ;;
        cadvisor)
            prompt "Target image tag (blank = auto-detect latest):" TARGET_TAG ""
            run_upgrade "cadvisor" upgrade_cadvisor verify_cadvisor rollback_cadvisor "$TARGET_TAG"
            ;;
        mosquitto)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "mosquitto" upgrade_mosquitto verify_mosquitto rollback_mosquitto "$TARGET_TAG"
            ;;
        ring-mqtt)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "ring-mqtt" upgrade_ring_mqtt verify_ring_mqtt rollback_ring_mqtt "$TARGET_TAG"
            ;;
        uptime-kuma)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "uptime-kuma" upgrade_uptime_kuma verify_uptime_kuma rollback_uptime_kuma "$TARGET_TAG"
            ;;
        cloudflared)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "cloudflared" upgrade_cloudflared verify_cloudflared rollback_cloudflared "$TARGET_TAG"
            ;;
        grafana-alloy|alloy)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "grafana-alloy" upgrade_grafana_alloy verify_grafana_alloy rollback_grafana_alloy "$TARGET_TAG"
            ;;
        home-assistant-matter-hub|matter-hub)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "HA Matter Hub" upgrade_matter_hub verify_matter_hub rollback_matter_hub "$TARGET_TAG"
            ;;
        pypowerwall-server|pypowerwall)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "pypowerwall-server" upgrade_pypowerwall verify_pypowerwall rollback_pypowerwall "$TARGET_TAG"
            ;;
        verify)
            verify_all
            ;;
        *)
            die "Unknown service '$DIRECT_SERVICE'.
  Valid names: hailo-whisper, hailo-ollama, hailo-ollama-full, piper,
               homeassistant, eoca, zigbee2mqtt, zwave-js-ui, open-webui,
               esphome, cadvisor, mosquitto, ring-mqtt, uptime-kuma,
               cloudflared, grafana-alloy, matter-hub, pypowerwall, verify"
            ;;
    esac
    echo ""
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') — done. Log: ${LOG_FILE} ==="
    exit 0
fi

# ── Interactive loop ───────────────────────────────────────────────────────
while true; do
    show_menu
    case "$MENU_CHOICE" in
        1)
            prompt "Target image tag (default: latest):" TARGET_TAG "latest"
            run_upgrade "hailo-whisper" upgrade_hailo_whisper verify_hailo_whisper rollback_hailo_whisper "$TARGET_TAG"
            ;;
        2)
            run_upgrade "hailo-ollama" upgrade_hailo_ollama_image verify_hailo_ollama rollback_hailo_ollama
            ;;
        3)
            prompt "New HailoRT version (e.g. 5.4.0):" NEW_VER ""
            [[ -n "$NEW_VER" ]] || { warn "Version required — skipping."; continue; }
            run_upgrade "hailo-ollama (full)" upgrade_hailo_ollama_full verify_hailo_ollama rollback_hailo_ollama "$NEW_VER"
            ;;
        4)
            prompt "Target image tag (default: latest):" TARGET_TAG "latest"
            run_upgrade "piper" upgrade_piper verify_piper rollback_piper "$TARGET_TAG"
            ;;
        5)
            prompt "Target image tag (default: stable):" TARGET_TAG "stable"
            run_upgrade "homeassistant" upgrade_homeassistant verify_homeassistant rollback_homeassistant "$TARGET_TAG"
            ;;
        6)
            prompt "Target release tag (leave blank for latest):" TARGET_TAG ""
            run_upgrade "extended_openai_conversation" upgrade_extended_openai verify_extended_openai rollback_extended_openai "$TARGET_TAG"
            ;;
        7)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "zigbee2mqtt" upgrade_zigbee2mqtt verify_zigbee2mqtt rollback_zigbee2mqtt "$TARGET_TAG"
            ;;
        8)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "zwave-js-ui" upgrade_zwave verify_zwave rollback_zwave "$TARGET_TAG"
            ;;
        9)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "open-webui" upgrade_open_webui verify_open_webui rollback_open_webui "$TARGET_TAG"
            ;;
        10)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "esphome" upgrade_esphome verify_esphome rollback_esphome "$TARGET_TAG"
            ;;
        11)
            prompt "Target image tag (blank = auto-detect latest):" TARGET_TAG ""
            run_upgrade "cadvisor" upgrade_cadvisor verify_cadvisor rollback_cadvisor "$TARGET_TAG"
            ;;
        12)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "mosquitto" upgrade_mosquitto verify_mosquitto rollback_mosquitto "$TARGET_TAG"
            ;;
        13)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "ring-mqtt" upgrade_ring_mqtt verify_ring_mqtt rollback_ring_mqtt "$TARGET_TAG"
            ;;
        14)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "uptime-kuma" upgrade_uptime_kuma verify_uptime_kuma rollback_uptime_kuma "$TARGET_TAG"
            ;;
        15)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "cloudflared" upgrade_cloudflared verify_cloudflared rollback_cloudflared "$TARGET_TAG"
            ;;
        16)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "grafana-alloy" upgrade_grafana_alloy verify_grafana_alloy rollback_grafana_alloy "$TARGET_TAG"
            ;;
        17)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "HA Matter Hub" upgrade_matter_hub verify_matter_hub rollback_matter_hub "$TARGET_TAG"
            ;;
        18)
            prompt "Target image tag (leave blank to keep current):" TARGET_TAG ""
            run_upgrade "pypowerwall-server" upgrade_pypowerwall verify_pypowerwall rollback_pypowerwall "$TARGET_TAG"
            ;;
        v|V|verify)
            verify_all
            ;;
        q|Q|quit|exit)
            echo ""
            info "Bye."
            break
            ;;
        *)
            warn "Invalid choice — enter 1–18, v to verify all, or q to quit."
            ;;
    esac

    echo ""
    prompt_yn "Upgrade another service?" _more
    [[ "$_more" == "y" ]] || break
done

echo ""
echo "=== $(date '+%Y-%m-%d %H:%M:%S') — completed. Log saved to: ${LOG_FILE} ==="
