#!/usr/bin/env bash
# ============================================================
# 01-install-hailo-voice-assistant.sh
# Full-stack Hailo Voice Assistant install on Raspberry Pi 5.
# All LLM inference runs on the Hailo-10H NPU — no CPU Ollama.
#
#  HailoRT v5.3.0         — kernel driver + Python bindings
#  Whisper STT            — encoder on Hailo NPU, decoder on CPU
#                           exposed as Wyoming STT service (port 10300)
#  hailo-ollama (NPU LLM) — qwen2.5:1.5b on Hailo NPU (port 11434)
#  Piper TTS              — already running via Docker Compose (health-check only)
#  Home Assistant         — Wyoming integration (auto-discovers STT/TTS)
#  Extended OpenAI Convo  — HA custom component for device control
#
# Run from your Mac:  bash 01-install-hailo-voice-assistant.sh
#
# Override defaults with environment variables:
#   RPI_HOST              — SSH alias or hostname     (default: rpi.local)
#   RPI_USER              — Pi username               (default: pi)
#   HA_DIR                — HA compose dir on Pi      (default: /home/<user>/homeassistant)
#   HAILO_WHISPER_IMAGE   — Docker image for Whisper  (default: canthefason/wyoming-hailo-whisper)
#   GENAI_REPO_DIR        — hailo_model_zoo_genai path on Pi  (default: /home/<user>/hailo_model_zoo_genai)
#   HAILO_OLLAMA_IMAGE    — Docker image for hailo-ollama     (default: canthefason/hailo-ollama)
#   HAILO_MODEL           — NPU model to use                  (default: qwen2.5:1.5b)
# ============================================================
set -euo pipefail

# ── Logging: tee all stdout+stderr to a log file next to this script ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/install-hailo-voice-assistant.log"
exec > >(tee "${LOG_FILE}") 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') — 01-install-hailo-voice-assistant.sh started ==="
echo ""

SSH_ALIAS="${RPI_HOST:-rpi.local}"
RPI_USER="${RPI_USER:-pi}"
HA_DIR="${HA_DIR:-/home/${RPI_USER}/homeassistant}"
HAILO_WHISPER_IMAGE="${HAILO_WHISPER_IMAGE:-canthefason/wyoming-hailo-whisper}"
HAILO_VERSION="5.3.0"
WYOMING_STT_PORT=10300
GENAI_REPO_DIR="${GENAI_REPO_DIR:-/home/${RPI_USER}/hailo_model_zoo_genai}"
HAILO_OLLAMA_BIN="/usr/local/bin/hailo-ollama"
HAILO_OLLAMA_PORT=11434
COMPOSE_FILE="${HA_DIR}/compose.yaml"
HAILO_OLLAMA_IMAGE="${HAILO_OLLAMA_IMAGE:-canthefason/hailo-ollama}"
IMAGE_TAG="${HAILO_OLLAMA_IMAGE}:latest"
HAILO_MODEL="${HAILO_MODEL:-qwen2.5:1.5b}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()     { echo -e "${GREEN}  ✔  $*${NC}"; }
info()   { echo -e "${CYAN}  →  $*${NC}"; }
header() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
die()    { echo -e "${RED}  ✘  $*${NC}" >&2; echo "=== FAILED: $* ==="; exit 1; }

confirm() {
    local msg="${1:-Continue?}"
    echo -e "\n${YELLOW}  ▶  ${msg}${NC}"
    echo ""
}

pi() {
    ssh "${RPI_USER}@${SSH_ALIAS}" "bash -l -s" <<< "$@"
}

pi_copy() {
    scp -r "$1" "${RPI_USER}@${SSH_ALIAS}:$2"
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Hailo Voice Assistant — Full Stack Install v${HAILO_VERSION}     ║${NC}"
echo -e "${CYAN}║   HailoRT · Whisper(NPU) · hailo-ollama(NPU) · HA     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 0 — Pre-flight
# ═══════════════════════════════════════════════════════════════
header "STEP 0 — Pre-flight checks"

info "Testing SSH connection..."
OUT=$(pi "echo 'SSH OK'") || die "Cannot reach Pi via SSH alias '$SSH_ALIAS'. Run 00-setup-ssh.sh first."
echo "$OUT" | grep -q "SSH OK" || die "SSH test failed — unexpected output: $OUT"
ok "SSH connection: healthy"

info "Checking OS and architecture..."
pi "
  . /etc/os-release
  ARCH=\$(uname -m)
  echo \"  OS   : \$PRETTY_NAME\"
  echo \"  Arch : \$ARCH\"
  [[ \"\$ARCH\" == aarch64 ]] || { echo 'ERROR: need 64-bit Pi OS (aarch64)'; exit 1; }
  echo 'ARCH_OK'
"
ok "64-bit Pi OS: confirmed"

info "Checking Hailo hardware presence..."
pi "
  if lspci 2>/dev/null | grep -qi hailo; then
    CHIP=\$(lspci | grep -i hailo | grep -oP 'Hailo-\w+' | head -1 || echo 'Hailo')
    echo \"  \$CHIP detected via PCIe (M.2 AI Kit) — good\"
    ls /dev/h1x* 2>/dev/null && echo '  Device node already present.' || echo '  Device node not yet created (driver not installed — expected at this stage)'
  else
    echo '  Hailo hardware not yet visible in lspci (driver not installed — expected at this stage)'
  fi
"

info "Checking hailo_model_zoo_genai repo..."
pi "
  test -d $GENAI_REPO_DIR || { echo \"ERROR: $GENAI_REPO_DIR not found — clone it before running this script\"; exit 1; }
  cd $GENAI_REPO_DIR && git log --oneline -1 2>/dev/null || true
  echo 'GENAI_REPO_OK'
" | grep 'GENAI_REPO_OK' || die "hailo_model_zoo_genai repo not found at $GENAI_REPO_DIR on Pi."
ok "hailo_model_zoo_genai repo: present"

info "Discovering available NPU models on Pi..."
AVAILABLE_MODELS=$(pi "
  MANIFEST_DIR=/usr/local/share/hailo-ollama/models/manifests
  if [ ! -d \"\$MANIFEST_DIR\" ]; then exit 0; fi
  find \"\$MANIFEST_DIR\" -name manifest.json 2>/dev/null | while IFS= read -r f; do
    rel=\$(echo \"\$f\" | sed \"s|^\$MANIFEST_DIR/||; s|/manifest.json\$||\")
    depth=\$(echo \"\$rel\" | tr -cd '/' | wc -c)
    if [ \"\$depth\" -eq 0 ]; then
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
    echo "  (no manifests yet — model will be pulled in Step 4)"
fi
info "Selected model: ${HAILO_MODEL}"

info "Checking internet access on Pi..."
pi "curl -s --max-time 5 https://hailo.ai > /dev/null && echo '  Internet: OK'" \
    || die "Pi cannot reach the internet — required for package downloads."
ok "Internet: reachable"

confirm "Pre-flight passed. Ready to start the installation?"

# ═══════════════════════════════════════════════════════════════
# STEP 1 — System update & prerequisites
# ═══════════════════════════════════════════════════════════════
header "STEP 1 — System update & prerequisites"

pi "
  set -e
  export DEBIAN_FRONTEND=noninteractive

  # ── Repair any broken dpkg state before touching apt ──
  if sudo dpkg --configure -a --dry-run 2>&1 | grep -q 'hailort-pcie-driver'; then
    echo '  hailort-pcie-driver is in a broken dpkg state — repairing...'
    docker stop hailo-whisper 2>/dev/null || true
    sudo rmmod hailo1x_pci 2>/dev/null || true
    sudo dpkg --configure -a 2>&1 | tail -5
    docker start hailo-whisper 2>/dev/null || true
  else
    echo '  No broken dpkg state detected.'
  fi
  sudo apt-get install -f -y -qq 2>&1 | grep -v '^$' || true

  echo '  Running apt update...'
  sudo apt-get update -qq
  echo '  Installing packages...'
  sudo apt-get install -y --no-install-recommends \
    curl wget git build-essential cmake \
    python3-pip python3-venv python3-dev \
    libsndfile1 libportaudio2 portaudio19-dev \
    ffmpeg alsa-utils \
    dkms \
    docker-compose-plugin 2>/dev/null || true
  # linux-headers-rpi-2712 is the Pi 5 (BCM2712) meta-package — always tracks the running kernel
  sudo apt-get install -y linux-headers-rpi-2712
  echo 'APT_PREREQS_OK'
" | grep -E 'APT_PREREQS_OK|already'
ok "System prerequisites: installed"

# ═══════════════════════════════════════════════════════════════
# STEP 2 — HailoRT v5.3.0 (runtime + kernel driver + Python bindings)
# ═══════════════════════════════════════════════════════════════
header "STEP 2 — HailoRT ${HAILO_VERSION} (runtime + kernel driver + Python bindings)"

pi "
  set -e

  # ── Remove stale Hailo developer CDN apt source if present ──
  STALE=\$(grep -rl 'hailo' /etc/apt/sources.list.d/ 2>/dev/null || true)
  if [[ -n \"\$STALE\" ]]; then
    echo \"  Removing stale Hailo apt source(s): \$STALE\"
    echo \"\$STALE\" | xargs sudo rm -f
    sudo apt-get update -qq
  else
    echo '  No stale Hailo apt sources found.'
  fi

  echo '  Scanning home directory for HailoRT ${HAILO_VERSION} .deb files...'
  ls ~/*.deb 2>/dev/null || echo '  (no .deb files found in ~)'

  DRIVER_DEB=\$(ls ~/hailort*pcie*driver*${HAILO_VERSION}*.deb ~/hailort*driver*${HAILO_VERSION}*.deb \
    2>/dev/null | head -1 || true)
  RUNTIME_DEB=\$(ls ~/hailort_${HAILO_VERSION}*.deb ~/hailort-${HAILO_VERSION}*.deb \
    ~/hailort*${HAILO_VERSION}*arm64*.deb ~/hailort*${HAILO_VERSION}*aarch64*.deb \
    2>/dev/null | grep -v 'driver\|dkms\|pcie' | head -1 || true)

  [[ -n \"\$DRIVER_DEB\" ]] || { echo \"  ERROR: no pcie-driver .deb found for v${HAILO_VERSION} in ~\"; ls ~/*.deb 2>/dev/null; exit 1; }
  [[ -n \"\$RUNTIME_DEB\" ]] || { echo \"  ERROR: no runtime .deb found for v${HAILO_VERSION} in ~\"; ls ~/*.deb 2>/dev/null; exit 1; }

  echo \"  Driver  : \$DRIVER_DEB\"
  echo \"  Runtime : \$RUNTIME_DEB\"

  RUNTIME_INSTALLED=\$(dpkg-query -W -f='\${Version}' hailort 2>/dev/null || true)
  DRIVER_INSTALLED=\$(dpkg-query -W -f='\${Version}' hailort-pcie-driver 2>/dev/null || true)

  if [[ \"\$RUNTIME_INSTALLED\" == \"${HAILO_VERSION}\" && \"\$DRIVER_INSTALLED\" == \"${HAILO_VERSION}\" ]]; then
    echo \"  hailort ${HAILO_VERSION} and hailort-pcie-driver ${HAILO_VERSION} already installed — skipping dpkg.\"
  else
    echo \"  Installed: hailort=\${RUNTIME_INSTALLED:-none}  hailort-pcie-driver=\${DRIVER_INSTALLED:-none}\"
    echo '  Installing .deb packages...'
    sudo dpkg -i \"\$DRIVER_DEB\" \"\$RUNTIME_DEB\"
    sudo apt-get install -f -y -qq
  fi

  echo '  Checking DKMS build status...'
  DKMS_STATUS=\$(dkms status | grep -i hailo || true)
  echo \"  \${DKMS_STATUS:-no hailo entry yet}\"
  if echo \"\$DKMS_STATUS\" | grep -q 'installed'; then
    echo '  DKMS module already installed for running kernel — skipping autoinstall.'
  else
    echo '  Running dkms autoinstall...'
    sudo dkms autoinstall 2>&1 | tail -5
    dkms status | grep -i hailo || echo '  ⚠  Still no hailo entry in dkms status'
  fi

  HAILO_WHEEL=\$(find /usr/lib/hailo* /usr/share/hailo* \$HOME -maxdepth 2 \
    -name 'hailo_platform*.whl' 2>/dev/null | head -1 || true)
  if [[ -n \"\$HAILO_WHEEL\" ]]; then
    echo \"  Installing Python wheel: \$HAILO_WHEEL\"
    pip3 install \"\$HAILO_WHEEL\" --break-system-packages -q
  else
    sudo apt-get install -y python3-hailort 2>/dev/null \
      || pip3 install hailort==${HAILO_VERSION} --break-system-packages -q 2>/dev/null \
      || echo '  ⚠  hailo_platform wheel not found — may need manual install'
  fi

  sudo usermod -aG hailo \$(whoami) 2>/dev/null || true
  echo 'HAILORT_INSTALLED'
" | grep -E 'HAILORT_INSTALLED|Driver\s*:|Runtime\s*:|Removing|wheel|\.deb'
ok "HailoRT packages: installed"

info "Verifying Hailo firmware via hailortcli..."
pi "
  sudo hailortcli fw-control identify --target /dev/h1x-0 2>/dev/null \
    || sudo hailortcli fw-control identify 2>/dev/null \
    && echo 'HAILO_FW_OK'
" | grep -E 'HAILO_FW_OK|Device|Serial|firmware|version|Hailo' \
  || warn "Firmware check skipped — may need a reboot for the DKMS driver to load."

info "Checking hailortcli version..."
HAILORT_VER=$(pi "hailortcli --version 2>/dev/null | head -1 || echo unknown") || true
echo "  $HAILORT_VER"
if ! echo "$HAILORT_VER" | grep -q "$HAILO_VERSION"; then
    die "HailoRT $HAILO_VERSION required but found: $HAILORT_VER"
fi
ok "HailoRT $HAILO_VERSION: confirmed"

confirm "HailoRT v${HAILO_VERSION} installed. Proceed to Whisper (NPU-accelerated STT)?"

# ═══════════════════════════════════════════════════════════════
# STEP 3 — Whisper STT (Hailo NPU encoder + Wyoming server)
#           Exposed as Wyoming STT service on port 10300
# ═══════════════════════════════════════════════════════════════
header "STEP 3 — Whisper STT (Hailo NPU encoder + Wyoming server)"

info "Reading existing compose file on Pi..."
pi "cat $COMPOSE_FILE" || die "Cannot read $COMPOSE_FILE on Pi."

pi "
  set -e
  if grep -q 'hailo-whisper' $COMPOSE_FILE; then
    echo '  hailo-whisper already in compose file — skipping add.'
  else
    echo '  Adding hailo-whisper service to $COMPOSE_FILE...'
    HAILO_DEV=\$(ls /dev/h1x* 2>/dev/null | head -1 || echo '/dev/h1x-0')
    echo \"  Hailo device: \$HAILO_DEV\"
    cat << EOF >> $COMPOSE_FILE

  hailo-whisper:
    image: ${HAILO_WHISPER_IMAGE}
    container_name: hailo-whisper
    restart: unless-stopped
    devices:
      - \${HAILO_DEV}:\${HAILO_DEV}
    ports:
      - \"${WYOMING_STT_PORT}:${WYOMING_STT_PORT}\"
    group_add:
      - \$(getent group hailo | cut -d: -f3)
    environment:
      - HAILO_VDEVICE_GROUP_ID=SHARED
EOF
    echo '  Service block appended.'
  fi
  echo 'COMPOSE_UPDATED'
" | grep -E 'COMPOSE_UPDATED|already|appended'
ok "compose.yaml: hailo-whisper service present"

info "Verifying Hailo device node exists before starting container..."
pi "
  if ls /dev/h1x* 2>/dev/null | head -1; then
    echo '  Hailo device node present.'
    echo 'HAILO_DEV_OK'
  else
    echo '  /dev/h1x-0 not found — attempting to load kernel module...'
    if sudo modprobe hailo1x_pci 2>/dev/null; then
      sleep 2
      if ls /dev/h1x* 2>/dev/null | head -1; then
        echo '  Module loaded, device node created.'
        echo 'HAILO_DEV_OK'
      else
        echo '  ✘  hailo1x_pci module loaded but /dev/h1x-0 still missing.'
        lsmod | grep hailo || echo '  (not in lsmod)'
        lspci | grep -i hailo || echo '  (hailo not visible in lspci)'
        find /lib/modules/\$(uname -r)/updates -name '*hailo*' 2>/dev/null || echo '  (no hailo .ko in updates/)'
        echo '  Check that the M.2 AI Kit is properly seated.'
        exit 1
      fi
    else
      echo '  modprobe failed — attempting dkms autoinstall as recovery...'
      sudo apt-get install -y linux-headers-rpi-2712 -qq 2>/dev/null || true
      sudo dkms autoinstall 2>&1 | tail -5
      if sudo modprobe hailo1x_pci 2>/dev/null && ls /dev/h1x* 2>/dev/null | head -1; then
        echo '  DKMS rebuild succeeded, module now loaded.'
        echo 'HAILO_DEV_OK'
      else
        echo '  ✘  DKMS build or modprobe still failing. Full diagnostics:'
        dkms status
        lspci | grep -i hailo || echo '  (not found in lspci)'
        sudo dmesg | grep -i hailo | tail -10 || true
        echo '  Fix manually, then re-run this script.'
        exit 1
      fi
    fi
  fi
" | grep -E 'HAILO_DEV_OK|present|created'
ok "Hailo device node: /dev/h1x-0 ready"

info "Checking hailo-whisper image..."
pi "
  set -e
  if docker images -q ${HAILO_WHISPER_IMAGE} 2>/dev/null | grep -q .; then
    echo '  Image already present locally — skipping pull.'
  else
    echo '  Image not found locally — pulling...'
    cd ${HA_DIR} && docker compose pull hailo-whisper \
      || { echo '  ✘  Pull failed and no local image exists'; exit 1; }
  fi
  echo 'PULL_OK'
" | grep 'PULL_OK'
ok "hailo-whisper image: ready"

info "Starting hailo-whisper container..."
pi "
  cd ${HA_DIR}
  docker compose up -d hailo-whisper
  sleep 4
  docker compose ps hailo-whisper
  echo 'CONTAINER_STARTED'
" | grep -E 'CONTAINER_STARTED|running|Up'
ok "hailo-whisper container: started"

info "Checking Wyoming STT port $WYOMING_STT_PORT is listening..."
pi "
  for i in 1 2 3; do
    if ss -tlnp | grep -q :${WYOMING_STT_PORT}; then
      ss -tlnp | grep :${WYOMING_STT_PORT}
      echo 'PORT_LISTENING'
      exit 0
    fi
    echo \"  Port ${WYOMING_STT_PORT} not yet open (attempt \$i/3) — waiting 5s...\"
    sleep 5
  done
  echo '  ✘  Port ${WYOMING_STT_PORT} is NOT listening after 15s. Diagnostics:'
  docker inspect hailo-whisper --format 'State: {{.State.Status}}  RestartCount: {{.RestartCount}}' 2>/dev/null || true
  docker logs hailo-whisper --tail 40 2>&1 || true
  ss -tlnp
  exit 1
"
ok "Wyoming STT endpoint: listening on port $WYOMING_STT_PORT"

confirm "Whisper (Hailo NPU + Wyoming) is healthy. Proceed to hailo-ollama NPU LLM?"

# ═══════════════════════════════════════════════════════════════
# STEP 4 — hailo-ollama NPU LLM (Docker Compose, Hailo-10H)
# ═══════════════════════════════════════════════════════════════
header "STEP 4 — hailo-ollama NPU LLM (${HAILO_MODEL})"

# ── 4a: Build hailo-ollama binary from source ────────────────
info "Building hailo-ollama against HailoRT ${HAILO_VERSION}..."
BUILD_OUT=""; BUILD_RC=0
BUILD_OUT=$(pi "
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

  echo '  Building (5-15 minutes on Pi 5 — please wait)...'
  cmake --build build --config Release -- -j4 2>&1 | tail -10

  echo '  Installing to /usr/local/bin...'
  sudo cmake --install build 2>&1 | tail -5

  echo 'BUILD_DONE'
") || BUILD_RC=$?
echo "$BUILD_OUT"
[[ $BUILD_RC -eq 0 ]] || die "Build step failed (exit $BUILD_RC) — see output above."
if echo "$BUILD_OUT" | grep -q "BUILD_SKIP"; then
    ok "hailo-ollama: already up-to-date"
elif echo "$BUILD_OUT" | grep -q "BUILD_DONE"; then
    ok "hailo-ollama: built and installed"
else
    die "Build completed but expected BUILD_DONE/BUILD_SKIP token missing."
fi

info "Verifying binary links against libhailort.so.${HAILO_VERSION}..."
LDD_OUT=$(pi "ldd $HAILO_OLLAMA_BIN 2>&1 | grep hailort") || true
echo "  $LDD_OUT"
if ! echo "$LDD_OUT" | grep -q "${HAILO_VERSION}"; then
    die "Binary not linked against libhailort.so.${HAILO_VERSION} — check build."
fi
ok "Binary links: libhailort.so.${HAILO_VERSION} ✔"

# ── 4b: Pull Docker image ────────────────────────────────────
info "Pulling Docker image: $IMAGE_TAG..."
DOCKER_OUT=""; DOCKER_RC=0
DOCKER_OUT=$(pi "
  set -e
  docker pull ${IMAGE_TAG} 2>&1 | tail -5
  echo 'IMAGE_READY'
") || DOCKER_RC=$?
echo "$DOCKER_OUT"
[[ $DOCKER_RC -eq 0 ]] || die "docker pull failed (exit $DOCKER_RC) — see output above."
echo "$DOCKER_OUT" | grep -q "IMAGE_READY" || die "docker pull completed but IMAGE_READY token missing."
ok "Docker image $IMAGE_TAG: pulled"

# ── 4c: Update compose.yaml ──────────────────────────────────
info "Updating compose.yaml for hailo-ollama..."
COMPOSE_OUT=""; COMPOSE_RC=0
COMPOSE_OUT=$(pi "
  set -e
  COMPOSE=${COMPOSE_FILE}

  HAILO_DEV=\$(ls /dev/h1x* 2>/dev/null | head -1)
  HAILO_GID=\$(stat -c '%g' \"\$HAILO_DEV\" 2>/dev/null || echo '107')
  echo \"  Hailo device GID: \$HAILO_GID\"

  cp \"\$COMPOSE\" \"\${COMPOSE}.bak\"
  echo '  Backed up compose.yaml → compose.yaml.bak'

  python3 << PYEOF
import re, sys

COMPOSE_FILE = '${COMPOSE_FILE}'
IMAGE_TAG    = '${IMAGE_TAG}'
HAILO_GID    = '\$HAILO_GID'
PORT         = '${HAILO_OLLAMA_PORT}'

with open(COMPOSE_FILE, 'r') as f:
    content = f.read()

# Remove any existing hailo-ollama block (idempotent re-runs)
lines = content.splitlines(keepends=True)
new_lines = []
skip = False
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if re.match(r'^  hailo-ollama:\s*\$', line):
        skip = True
        i += 1
        continue
    if skip:
        if stripped and not stripped.startswith('#') and indent <= 2 and not re.match(r'^\s*\$', line):
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
      - "{port}:{port}"
    volumes:
      - /usr/local/share/hailo-ollama:/usr/local/share/hailo-ollama
      - /usr/local/bin/hailo-ollama:/usr/local/bin/hailo-ollama:ro
      - /usr/lib/libhailort.so.5.3.0:/usr/lib/libhailort.so.5.3.0:ro
      - /usr/lib/aarch64-linux-gnu/libusb-1.0.so.0:/usr/lib/aarch64-linux-gnu/libusb-1.0.so.0:ro
    devices:
      - /dev/h1x-0:/dev/h1x-0
    group_add:
      - "{gid}"
    environment:
      - OLLAMA_KEEP_ALIVE=-1
      - HAILO_OLLAMA_VDEVICE_GROUP_ID=SHARED
      - XDG_DATA_HOME=/usr/local/share
      - LD_LIBRARY_PATH=/usr/lib
'''.format(image=IMAGE_TAG, port=PORT, gid=HAILO_GID)

content = re.sub(
    r'(^services:\s*\n)',
    r'\1' + service_block,
    content,
    count=1,
    flags=re.MULTILINE
)
print('  hailo-ollama service block inserted/updated in compose.yaml')

# Ensure HAILO_VDEVICE_GROUP_ID=SHARED is set in every other service that uses /dev/h1x-0
VDEVICE_GROUP = 'SHARED'
VDEVICE_ENV_LINE = '      - HAILO_VDEVICE_GROUP_ID=' + VDEVICE_GROUP + '\n'
lines = content.splitlines(keepends=True)
in_services = False
cur_service = None
cur_start = None
service_ranges = []
for idx, line in enumerate(lines):
    if re.match(r'^services:\s*\$', line):
        in_services = True
        continue
    if not in_services:
        continue
    if line and not line[0].isspace() and not re.match(r'^\s*\$', line):
        if cur_service is not None:
            service_ranges.append((cur_service, cur_start, idx))
        in_services = False
        cur_service = None
        continue
    m = re.match(r'^  (\w[\w-]*):\s*\$', line)
    if m:
        if cur_service is not None:
            service_ranges.append((cur_service, cur_start, idx))
        cur_service = m.group(1)
        cur_start = idx
if cur_service is not None:
    service_ranges.append((cur_service, cur_start, len(lines)))

for svc_name, start, end in service_ranges:
    if svc_name == 'hailo-ollama':
        continue
    svc_lines = lines[start:end]
    if not any('/dev/h1x-0' in l for l in svc_lines):
        continue
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
        print('  Updated HAILO_VDEVICE_GROUP_ID=' + VDEVICE_GROUP + ' in service: ' + svc_name)
        continue
    env_idx = None
    for j, l in enumerate(svc_lines):
        if re.match(r'    environment:\s*\$', l):
            env_idx = j
            break
    if env_idx is not None:
        svc_lines.insert(env_idx + 1, VDEVICE_ENV_LINE)
    else:
        insert_at = len(svc_lines)
        for j, l in enumerate(svc_lines):
            if re.match(r'    devices:\s*\$', l):
                insert_at = j
                break
        svc_lines.insert(insert_at, VDEVICE_ENV_LINE)
        svc_lines.insert(insert_at, '    environment:\n')
    lines[start:end] = svc_lines
    print('  Added HAILO_VDEVICE_GROUP_ID=' + VDEVICE_GROUP + ' to service: ' + svc_name)

content = ''.join(lines)
with open(COMPOSE_FILE, 'w') as f:
    f.write(content)
print('  compose.yaml updated successfully')
PYEOF

  echo 'COMPOSE_UPDATED'
") || COMPOSE_RC=$?
echo "$COMPOSE_OUT"
[[ $COMPOSE_RC -eq 0 ]] || die "compose.yaml update failed (exit $COMPOSE_RC) — see output above."
echo "$COMPOSE_OUT" | grep -q "COMPOSE_UPDATED" || die "Unexpected output from compose update step."
ok "compose.yaml: hailo-ollama service present"

# ── 4d: Start container ──────────────────────────────────────
info "Starting hailo-ollama container..."
UP_OUT=""; UP_RC=0
UP_OUT=$(pi "
  set -e
  sudo mkdir -p /usr/local/share/hailo-ollama/models/manifests/hailo-ollama
  sudo mkdir -p /usr/local/share/hailo-ollama/models/blob
  sudo chown -R ${RPI_USER}:${RPI_USER} /usr/local/share/hailo-ollama/models/manifests/hailo-ollama
  sudo chown -R ${RPI_USER}:${RPI_USER} /usr/local/share/hailo-ollama/models/blob
  echo '  Host model dirs: ready'
  cd ${HA_DIR}

  # Restart hailo-whisper to activate HAILO_VDEVICE_GROUP_ID before hailo-ollama starts
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
    echo \"  Restarting \$WYOMING_SVC to activate HAILO_VDEVICE_GROUP_ID...\"
    docker compose restart \"\$WYOMING_SVC\" 2>&1 | tail -5 || true
    sleep 5
  fi

  docker compose up -d hailo-ollama 2>&1
  echo 'COMPOSE_UP_DONE'
") || UP_RC=$?
echo "$UP_OUT"
[[ $UP_RC -eq 0 ]] || die "docker compose up failed (exit $UP_RC) — see output above."
echo "$UP_OUT" | grep -q "COMPOSE_UP_DONE" || die "Unexpected output from compose up step."
ok "hailo-ollama container: started"

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
    pi "docker logs hailo-ollama --tail 40 2>&1" || true
    die "hailo-ollama failed to start within 90s. See logs above."
fi

info "Checking startup logs for NPU errors..."
sleep 2
STARTUP_LOGS=$(pi "docker logs hailo-ollama 2>&1 | tail -30") || true
echo "$STARTUP_LOGS"
if echo "$STARTUP_LOGS" | grep -qi "HAILO_OUT_OF_PHYSICAL_DEVICES"; then
    warn "NPU device sharing conflict detected — HAILO_OUT_OF_PHYSICAL_DEVICES in logs."
    pi "
      echo '  hailo-ollama env:'; docker exec hailo-ollama env 2>/dev/null | grep -i hailo || echo '  (none)'
      echo '  hailo-whisper env:'; docker exec hailo-whisper env 2>/dev/null | grep -i hailo || echo '  (none)'
    " || true
    warn "Both containers must use HAILO_VDEVICE_GROUP_ID=SHARED."
fi

# ── 4e: Pull model ───────────────────────────────────────────
info "Pulling model: ${HAILO_MODEL}..."
MODEL_OUT=""; MODEL_RC=0
MODEL_OUT=$(pi "
  echo '  Model store contents:'
  find /usr/local/share/hailo-ollama/models/ 2>/dev/null | head -40 || echo '  (empty)'

  MODEL_PATH=\$(echo '${HAILO_MODEL}' | tr ':' '/')
  BLOB_COUNT=\$(find /usr/local/share/hailo-ollama/models/blob/ -type f 2>/dev/null | wc -l)
  MANIFEST_FILE=/usr/local/share/hailo-ollama/models/manifests/\${MODEL_PATH}/manifest.json

  if [ -f \"\$MANIFEST_FILE\" ] && [ \"\$BLOB_COUNT\" -gt 0 ]; then
    echo \"  Model manifest + \$BLOB_COUNT blob(s) found — skipping pull.\"
    echo 'MODEL_READY'
    exit 0
  elif [ -f \"\$MANIFEST_FILE\" ] && [ \"\$BLOB_COUNT\" -eq 0 ]; then
    echo \"  Manifest found but blob/ is empty — pulling HEF data.\"
  else
    echo \"  Manifest not found at \$MANIFEST_FILE — pulling model.\"
  fi

  # Stop hailo-whisper temporarily — hailo-ollama needs exclusive NPU access during pull
  cd ${HA_DIR}
  echo '  Stopping hailo-whisper temporarily (NPU needed for pull)...'
  docker compose stop hailo-whisper 2>&1 | tail -3 || true
  sleep 2

  MANIFEST_JSON=\$(cat /usr/local/share/hailo-ollama/models/manifests/\${MODEL_PATH}/manifest.json 2>/dev/null)
  BLOB_HASH=\$(echo \"\$MANIFEST_JSON\" | python3 -c \"
import json,sys
d=json.load(sys.stdin)
print(d.get('hef_h10h',''))
\" 2>/dev/null)
  echo \"  HEF blob hash: \$BLOB_HASH\"

  if [ -z \"\$BLOB_HASH\" ]; then
    echo '  ERROR: hef_h10h field missing from manifest.'
    docker compose start hailo-whisper 2>&1 | tail -3 || true
    echo 'PULL_FAILED'; exit 1
  fi

  BLOB_FILE=/usr/local/share/hailo-ollama/models/blob/sha256_\${BLOB_HASH}

  # Migrate from old blobs/ (plural) location if present
  OLD_BLOB=/usr/local/share/hailo-ollama/models/blobs/sha256_\${BLOB_HASH}
  if [ -f \"\$OLD_BLOB\" ] && [ ! -f \"\$BLOB_FILE\" ]; then
    echo '  Migrating blob from blobs/ to blob/...'
    mkdir -p /usr/local/share/hailo-ollama/models/blob
    mv \"\$OLD_BLOB\" \"\$BLOB_FILE\"
    echo \"  Migrated: \$BLOB_FILE\"
  fi

  DL_URL=\"https://dev-public.hailo.ai/blob/sha256_\${BLOB_HASH}\"
  echo \"  Downloading: \$DL_URL\"
  HTTP_CODE=\$(curl -w '%{http_code}' -o \"\${BLOB_FILE}.tmp\" -L --max-time 900 -s \
    --retry 2 --retry-delay 5 \"\$DL_URL\" 2>&1)
  echo \"  HTTP status: \$HTTP_CODE\"
  if [ \"\$HTTP_CODE\" = '200' ] && [ -s \"\${BLOB_FILE}.tmp\" ]; then
    echo '  Download complete — verifying SHA256...'
    ACTUAL_HASH=\$(sha256sum \"\${BLOB_FILE}.tmp\" | cut -d' ' -f1)
    if [ \"\$ACTUAL_HASH\" = \"\$BLOB_HASH\" ]; then
      mv \"\${BLOB_FILE}.tmp\" \"\$BLOB_FILE\"
      echo '  SHA256 verified ✔'
    else
      rm -f \"\${BLOB_FILE}.tmp\"
      echo \"  SHA256 mismatch: expected \$BLOB_HASH got \$ACTUAL_HASH\"
      docker compose start hailo-whisper 2>&1 | tail -3 || true
      echo 'PULL_FAILED'; exit 1
    fi
  else
    rm -f \"\${BLOB_FILE}.tmp\"
    echo \"  Download failed (HTTP \$HTTP_CODE).\"
    curl -s -L --max-time 10 \"\$DL_URL\" | head -5 || true
    docker compose start hailo-whisper 2>&1 | tail -3 || true
    echo 'PULL_FAILED'; exit 1
  fi

  echo '  Restarting hailo-whisper...'
  docker compose start hailo-whisper 2>&1 | tail -3 || true
  echo 'MODEL_PULLED'
") || MODEL_RC=$?
echo "$MODEL_OUT"
[[ $MODEL_RC -eq 0 ]] || die "Model pull failed (exit $MODEL_RC)."
echo "$MODEL_OUT" | grep -qE "MODEL_READY|MODEL_PULLED" || die "Model pull: unexpected output."
ok "Model $HAILO_MODEL: ready"

# ── 4f: Smoke-test inference ─────────────────────────────────
info "Smoke-testing hailo-ollama inference (first load may take ~2 min)..."
INFER_OUT=""; INFER_RC=0
INFER_OUT=$(pi "
  STATUS=\$(docker inspect --format '{{.State.Status}}' hailo-ollama 2>/dev/null || echo 'missing')
  echo \"  Container status: \$STATUS\"
  if [ \"\$STATUS\" != 'running' ]; then
    docker logs hailo-ollama --tail 50 2>&1 || true
    echo 'CONTAINER_DOWN'
    exit 1
  fi

  echo '  Sending generate request (timeout 180s)...'
  RESPONSE=\$(curl -s --max-time 180 -X POST http://localhost:${HAILO_OLLAMA_PORT}/api/generate \
    -H 'Content-Type: application/json' \
    -d '{\"model\": \"${HAILO_MODEL}\", \"prompt\": \"Reply with exactly: INFERENCE_OK\", \"stream\": false}' 2>&1)
  CURL_RC=\$?
  echo \"  curl exit: \$CURL_RC\"
  echo \"  Response: \$RESPONSE\"
  if [ \$CURL_RC -ne 0 ]; then
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
    die "Smoke-test inference returned an error — see response above."
fi
if echo "$INFER_OUT" | grep -q "SMOKE_DONE"; then
    ok "hailo-ollama inference: working"
else
    warn "Smoke-test timed out — HEF model may still be loading. Verify manually:"
    warn "  curl -s http://${SSH_ALIAS}:${HAILO_OLLAMA_PORT}/api/tags"
fi

confirm "hailo-ollama NPU LLM is healthy. Proceed to Piper TTS check?"

# ═══════════════════════════════════════════════════════════════
# STEP 5 — Piper TTS (Docker Compose) — health check
# ═══════════════════════════════════════════════════════════════
header "STEP 5 — Piper TTS (Docker Compose) — health check"

info "Checking Docker Compose Piper container is running..."
pi "
  PIPER_CONTAINER=\$(docker ps --format '{{.Names}}' | grep -i piper | head -1 || true)
  if [[ -n \"\$PIPER_CONTAINER\" ]]; then
    echo \"  Piper container: \$PIPER_CONTAINER\"
    docker inspect \"\$PIPER_CONTAINER\" --format '  Status: {{.State.Status}}'
    echo 'PIPER_CONTAINER_OK'
  else
    echo '  No running Piper container found.'
    docker ps --format '  {{.Names}} ({{.Image}})'
    echo ''
    echo '  ⚠  Start it with: docker compose up -d piper'
    echo 'PIPER_NOT_RUNNING'
  fi
"

info "Checking Piper Wyoming TTS port (default: 10200)..."
PIPER_PORT=$(pi "
  docker ps --format '{{.Ports}}' 2>/dev/null | grep -o '[0-9]*->10200' | cut -d'-' -f1 \
    || echo '10200'
" | tail -1)
pi "
  ss -tlnp | grep :${PIPER_PORT:-10200} && echo 'PIPER_PORT_OK' \
    || echo '  ⚠  Piper Wyoming port not detected — check your Docker Compose port mapping.'
" | grep -E 'PIPER_PORT_OK|⚠'

confirm "Piper checked. Proceed to Home Assistant Wyoming integration?"

# ═══════════════════════════════════════════════════════════════
# STEP 6 — Home Assistant Wyoming integration
# ═══════════════════════════════════════════════════════════════
header "STEP 6 — Home Assistant — Wyoming integration"

PI_IP=$(ssh "${RPI_USER}@${SSH_ALIAS}" "hostname -I | awk '{print \$1}'")
info "Pi IP address: $PI_IP"
info "Wyoming STT (Hailo Whisper) → tcp://${PI_IP}:${WYOMING_STT_PORT}"
info "Wyoming TTS (Piper Docker)  → tcp://${PI_IP}:10200  (adjust port if different)"

echo ""
echo -e "${CYAN}  To add these to Home Assistant:${NC}"
echo -e "  1. Open HA → Settings → Devices & Services → Add Integration"
echo -e "  2. Search for ${BOLD}Wyoming Protocol${NC}"
echo -e "  3. Add STT:  host=${PI_IP}  port=${WYOMING_STT_PORT}  → Hailo Whisper"
echo -e "  4. Add TTS:  host=${PI_IP}  port=10200              → Piper Docker"
echo -e "  5. In Settings → Voice Assistants, assign both services to your assistant."
echo ""

info "Verifying hailo-whisper container is still healthy..."
WHISPER_CHECK=$(pi "
  STATUS=\$(docker inspect hailo-whisper --format '{{.State.Status}}' 2>/dev/null || echo 'missing')
  echo \"  hailo-whisper container: \$STATUS\"
  [[ \"\$STATUS\" == 'running' ]] || { echo '  ✘  Container not running'; docker logs hailo-whisper --tail 20 2>&1; exit 1; }
  ss -tlnp | grep -q :${WYOMING_STT_PORT} || { echo '  ✘  Port ${WYOMING_STT_PORT} not listening'; exit 1; }
  echo 'WYOMING_STILL_OK'
")
echo "$WHISPER_CHECK"
[[ "$WHISPER_CHECK" == *WYOMING_STILL_OK* ]] || die "hailo-whisper health check failed"
ok "Wyoming STT container: still running"

confirm "Home Assistant integration steps noted. Install Extended OpenAI Conversation?"

# ═══════════════════════════════════════════════════════════════
# STEP 7 — Extended OpenAI Conversation custom component
# ═══════════════════════════════════════════════════════════════
header "STEP 7 — Extended OpenAI Conversation (hailo-ollama + HA device control)"

info "Installing extended_openai_conversation custom component..."
EOCA_OUT=""; EOCA_RC=0
EOCA_OUT=$(pi "
  CUSTOM_DIR=${HA_DIR}/config/custom_components
  EOCA_DIR=\$CUSTOM_DIR/extended_openai_conversation
  sudo mkdir -p \$CUSTOM_DIR

  if sudo test -d \$EOCA_DIR; then
    VER=\$(sudo python3 -c \"import json; print(json.load(open('\$EOCA_DIR/manifest.json'))['version'])\" 2>/dev/null || echo unknown)
    echo \"  extended_openai_conversation already installed (v\$VER) — skipping.\"
    echo 'EOCA_INSTALLED'
    exit 0
  fi
  set -e

  echo '  Fetching latest release info from GitHub...'
  RELEASE_JSON=\$(curl -sf https://api.github.com/repos/jekalmin/extended_openai_conversation/releases/latest)
  TAG=\$(echo \"\$RELEASE_JSON\" | python3 -c \"import json,sys; print(json.load(sys.stdin)['tag_name'])\")
  ZIP_URL=\$(echo \"\$RELEASE_JSON\" | python3 -c \"
import json, sys
rel = json.load(sys.stdin)
assets = [a['browser_download_url'] for a in rel.get('assets', []) if a['name'].endswith('.zip')]
print(assets[0] if assets else '')
\")
  if [[ -z \"\$ZIP_URL\" ]]; then
    ZIP_URL=\"https://github.com/jekalmin/extended_openai_conversation/archive/refs/tags/\${TAG}.zip\"
  fi
  echo \"  Downloading \$TAG: \$ZIP_URL\"
  curl -sL -o /tmp/eoca.zip \"\$ZIP_URL\"

  rm -rf /tmp/eoca_work && mkdir /tmp/eoca_work
  unzip -q /tmp/eoca.zip -d /tmp/eoca_work

  MANIFEST=\$(find /tmp/eoca_work -name manifest.json | head -1)
  [[ -n \"\$MANIFEST\" ]] || { echo '  ✘  manifest.json not found in zip'; ls -la /tmp/eoca_work/; exit 1; }
  INTEGRATION_DIR=\$(dirname \"\$MANIFEST\")
  sudo cp -r \"\$INTEGRATION_DIR\" \"\$EOCA_DIR\"
  rm -rf /tmp/eoca.zip /tmp/eoca_work

  VER=\$(sudo python3 -c \"import json; print(json.load(open('\$EOCA_DIR/manifest.json'))['version'])\" 2>/dev/null || echo unknown)
  echo \"  Installed extended_openai_conversation v\$VER\"
  echo 'EOCA_INSTALLED'
") || EOCA_RC=$?
echo "$EOCA_OUT"
[[ $EOCA_RC -eq 0 ]] || die "extended_openai_conversation install failed (exit $EOCA_RC)"
[[ "$EOCA_OUT" == *EOCA_INSTALLED* ]] || die "extended_openai_conversation install failed (no EOCA_INSTALLED token)"
ok "extended_openai_conversation: installed in config/custom_components/"

info "Restarting Home Assistant to load the new custom component..."
HA_OUT=""; HA_RC=0
HA_OUT=$(pi "
  cd ${HA_DIR}
  docker compose restart homeassistant 2>&1
  echo 'HA_RESTARTING'
") || HA_RC=$?
echo "$HA_OUT"
[[ $HA_RC -eq 0 ]] || die "Home Assistant restart failed (exit $HA_RC)"
[[ "$HA_OUT" == *HA_RESTARTING* ]] || die "Home Assistant restart failed (no HA_RESTARTING token)"
ok "Home Assistant: restarting (allow ~30s before opening the UI)"

info "Patching HA config entry to use hailo-ollama model..."
pi "
  STORAGE=${HA_DIR}/config/.storage/core.config_entries
  if [ ! -f \"\$STORAGE\" ]; then
    echo '  HA config entries storage not found — skipping patch (configure manually).'
    exit 0
  fi
  CURRENT_MODEL=\$(sudo python3 -c \"
import json
data = json.load(open('\$STORAGE'))
for e in data.get('data', {}).get('entries', []):
    if e.get('domain') == 'extended_openai_conversation':
        model = (e.get('options', {}).get('chat_model')
              or e.get('data', {}).get('chat_model')
              or e.get('options', {}).get('model')
              or e.get('data', {}).get('model')
              or 'not found')
        print(model)
        break
\" 2>/dev/null || echo 'unknown')
  echo \"  Extended OpenAI Conversation current model: \$CURRENT_MODEL\"
  if [ \"\$CURRENT_MODEL\" != '${HAILO_MODEL}' ]; then
    echo \"  Patching model → '${HAILO_MODEL}'...\"
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
                    e[section][key] = '${HAILO_MODEL}'
                    patched = True
if patched:
    json.dump(data, open('\$STORAGE', 'w'), indent=2)
    print('  Patched successfully')
else:
    print('  Model key not found — configure manually in HA UI')
\"
    echo '  Reload the integration: Settings → Devices & Services → Extended OpenAI Conversation → ⋮ → Reload'
  else
    echo '  Model already set to ${HAILO_MODEL} — no patch needed.'
  fi
" || true

echo ""
echo -e "${CYAN}  ── Configure Extended OpenAI Conversation in HA ──────────────────${NC}"
echo -e "  1. Wait ~30s, then open  http://${PI_IP}:8123"
echo -e "  2. Settings → Devices & Services → Add Integration"
echo -e "  3. Search  ${BOLD}Extended OpenAI Conversation${NC}"
echo -e "  4. Fill in:"
echo -e "       API Key : ollama           (any value — not checked)"
echo -e "       Base URL: http://localhost:${HAILO_OLLAMA_PORT}/v1"
echo -e "       Model   : ${HAILO_MODEL}"
echo -e "  5. Settings → Voice Assistants → edit your assistant"
echo -e "     → Conversation Agent: Extended OpenAI Conversation"
echo ""

confirm "Extended OpenAI Conversation configured. Run end-to-end smoke test?"

# ═══════════════════════════════════════════════════════════════
# STEP 8 — End-to-end smoke test
# ═══════════════════════════════════════════════════════════════
header "STEP 8 — End-to-end smoke test"

pi "
  set -e

  echo ''
  echo '[1/3] Hailo hardware + HailoRT...'
  hailortcli fw-control identify 2>/dev/null | grep -E 'Device|firmware|Serial' \
    || sudo hailortcli fw-control identify | grep -E 'Device|firmware|Serial'
  echo '  HAILO_SMOKE_OK'

  echo ''
  echo '[2/3] Wyoming Whisper container (STT)...'
  cd ${HA_DIR}
  STATUS=\$(docker compose ps hailo-whisper --format json 2>/dev/null \
    | python3 -c \"import json,sys; d=json.load(sys.stdin); print(d[0]['State'])\" 2>/dev/null \
    || docker inspect hailo-whisper --format '{{.State.Status}}' 2>/dev/null \
    || echo unknown)
  echo \"  hailo-whisper container: \$STATUS\"
  ss -tlnp | grep :${WYOMING_STT_PORT} | head -1
  echo '  WHISPER_SMOKE_OK'

  echo ''
  echo '[3/3] hailo-ollama NPU LLM...'
  curl -s http://localhost:${HAILO_OLLAMA_PORT}/api/tags | python3 -c \"
import json, sys
data = json.load(sys.stdin)
models = [m['name'] for m in data.get('models', [])]
print('  hailo-ollama models:', models)
print('  OLLAMA_SMOKE_OK')
\" 2>/dev/null || echo '  ⚠  /api/tags check failed — container may still be starting'
" 2>&1

ok "Smoke test: all components verified"

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Installation Complete!                      ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Component                Status    Notes              ║${NC}"
echo -e "${GREEN}║  ─────────────────────    ──────    ──────             ║${NC}"
echo -e "${GREEN}║  HailoRT ${HAILO_VERSION}           ✔         /dev/h1x*         ║${NC}"
echo -e "${GREEN}║  Whisper STT (NPU)        ✔         port ${WYOMING_STT_PORT} (Wyoming)  ║${NC}"
echo -e "${GREEN}║  hailo-ollama (NPU LLM)   ✔         port ${HAILO_OLLAMA_PORT}         ║${NC}"
echo -e "${GREEN}║  Piper TTS (Docker)       ✔         port 10200 (Wyoming)║${NC}"
echo -e "${GREEN}║  Ext. OpenAI Conversation ✔         custom_components/ ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Wyoming STT  tcp://${PI_IP}:${WYOMING_STT_PORT}             ║${NC}"
echo -e "${GREEN}║  Wyoming TTS  tcp://${PI_IP}:10200               ║${NC}"
echo -e "${GREEN}║  hailo-ollama http://${PI_IP}:${HAILO_OLLAMA_PORT}          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
warn "If /dev/h1x* shows 'permission denied', run: sudo reboot"
warn "After reboot your user will be in the 'hailo' group."
echo ""
echo -e "${CYAN}  Service management:${NC}"
echo -e "  ssh ${RPI_USER}@${SSH_ALIAS} 'docker logs hailo-whisper -f'    # Whisper STT logs"
echo -e "  ssh ${RPI_USER}@${SSH_ALIAS} 'docker logs hailo-ollama -f'     # hailo-ollama logs"
echo -e "  ssh ${RPI_USER}@${SSH_ALIAS} 'docker logs wyoming-piper -f'    # Piper TTS logs"
echo -e "  ssh ${RPI_USER}@${SSH_ALIAS} 'cd ${HA_DIR} && docker compose ps'  # all containers"
echo ""
echo "=== $(date '+%Y-%m-%d %H:%M:%S') — completed successfully ==="
echo "Log saved to: ${LOG_FILE}"
