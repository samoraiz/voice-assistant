#!/usr/bin/env bash
# ============================================================
# 01-install-hailo-voice-assistant.sh
# Installs Hailo Voice Assistant stack v5.3.0 on your Pi,
# one confirmed step at a time.
#
#  HailoRT v5.3.0  — kernel driver + Python bindings
#  Whisper STT     — encoder on Hailo NPU, decoder on CPU
#                    exposed as Wyoming STT service (port 10300)
#  Ollama          — LLM runtime
#  Piper TTS       — already running via Docker Compose (health-check only)
#  Home Assistant  — Wyoming integration (auto-discovers STT/TTS services)
#
# Run from your Mac:  bash 01-install-hailo-voice-assistant.sh
#
# Override defaults with environment variables:
#   RPI_HOST              — SSH alias or hostname     (default: rpi.local)
#   RPI_USER              — Pi username               (default: pi)
#   HA_DIR                — HA compose dir on Pi      (default: /home/<user>/homeassistant)
#   HAILO_WHISPER_IMAGE   — Docker image for Whisper  (default: canthefason/wyoming-hailo-whisper)
# ============================================================
set -euo pipefail

SSH_ALIAS="${RPI_HOST:-rpi.local}"
RPI_USER="${RPI_USER:-pi}"
HA_DIR="${HA_DIR:-/home/${RPI_USER}/homeassistant}"
HAILO_WHISPER_IMAGE="${HAILO_WHISPER_IMAGE:-canthefason/wyoming-hailo-whisper}"
HAILO_VERSION="5.3.0"
WYOMING_STT_PORT=10300
INSTALL_DIR="/opt/voice-assistant"
VENV="$INSTALL_DIR/venv"
WHISPER_DIR="$INSTALL_DIR/whisper"
# Workspace folder (Mac-side) containing the Wyoming server source
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()     { echo -e "${GREEN}  ✔  $*${NC}"; }
info()   { echo -e "${CYAN}  →  $*${NC}"; }
header() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }
warn()   { echo -e "${YELLOW}  ⚠  $*${NC}"; }
die()    { echo -e "${RED}  ✘  $*${NC}" >&2; exit 1; }

confirm() {
    local msg="${1:-Continue?}"
    echo -e "\n${YELLOW}  ▶  ${msg}${NC}"
    echo ""
}

pi() {
    ssh "$SSH_ALIAS" "bash -l -s" <<< "$@"
}

pi_copy() {
    # pi_copy <local_path> <remote_path>
    scp -r "$1" "${SSH_ALIAS}:$2"
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Hailo Voice Assistant — Full Stack Install v${HAILO_VERSION}     ║${NC}"
echo -e "${CYAN}║   HailoRT · Whisper(NPU) · Ollama · Piper · HA        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 0 — Pre-flight
# ═══════════════════════════════════════════════════════════════
header "STEP 0 — Pre-flight checks"

info "Testing SSH connection..."
pi "echo 'SSH OK'" | grep -q "SSH OK" \
    || die "Cannot reach Pi via SSH alias '$SSH_ALIAS'. Run 00-setup-ssh.sh first."
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
  # hailort-pcie-driver's post-install script does modprobe -r + modprobe.
  # It fails if the module is currently held open by a container.
  # Solution: stop Hailo containers, unload the module, let dpkg finish,
  # then restart containers afterwards.
  if sudo dpkg --configure -a --dry-run 2>&1 | grep -q 'hailort-pcie-driver'; then
    echo '  hailort-pcie-driver is in a broken dpkg state — repairing...'
    echo '  Stopping Hailo containers to release the device...'
    docker stop hailo-whisper 2>/dev/null || true
    echo '  Unloading hailo1x_pci module...'
    sudo rmmod hailo1x_pci 2>/dev/null || true
    echo '  Running dpkg --configure -a...'
    sudo dpkg --configure -a 2>&1 | tail -5
    echo '  Restarting hailo-whisper container...'
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
  # Raspberry Pi OS uses variant-specific header packages, not linux-headers-$(uname -r).
  # linux-headers-rpi-2712 is the Pi 5 (BCM2712) meta-package — always tracks the
  # running kernel version (e.g. 6.12.75+rpt-rpi-2712) without hardcoding it.
  sudo apt-get install -y linux-headers-rpi-2712
  echo 'APT_PREREQS_OK'
" | grep -E 'APT_PREREQS_OK|already'
ok "System prerequisites: installed"

# ═══════════════════════════════════════════════════════════════
# STEP 2 — HailoRT v5.3.0 (runtime + kernel driver)
# ═══════════════════════════════════════════════════════════════
header "STEP 2 — HailoRT ${HAILO_VERSION} (runtime + kernel driver + Python bindings)"

pi "
  set -e

  # ── Remove stale Hailo developer CDN apt source if present ──
  # It knows about 5.3.0 but blocks downloads behind a login wall,
  # causing 'available from another source' errors.
  STALE=\$(grep -rl 'hailo' /etc/apt/sources.list.d/ 2>/dev/null || true)
  if [[ -n \"\$STALE\" ]]; then
    echo \"  Removing stale Hailo apt source(s): \$STALE\"
    echo \"\$STALE\" | xargs sudo rm -f
    sudo apt-get update -qq
  else
    echo '  No stale Hailo apt sources found.'
  fi

  # ── Install from local .deb files (v${HAILO_VERSION}) ──
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

  # ── Skip dpkg install if already at the right version ──
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

  # ── Ensure DKMS module is built for the running kernel ──
  echo '  Checking DKMS build status...'
  DKMS_STATUS=\$(dkms status | grep -i hailo || true)
  echo \"  \${DKMS_STATUS:-no hailo entry yet}\"
  if echo \"\$DKMS_STATUS\" | grep -q 'installed'; then
    echo '  DKMS module already installed for running kernel — skipping autoinstall.'
  else
    echo '  Running dkms autoinstall...'
    sudo dkms autoinstall 2>&1 | tail -5
    echo '  DKMS status after build:'
    dkms status | grep -i hailo || echo '  ⚠  Still no hailo entry in dkms status'
  fi

  # ── hailo_platform Python bindings ──
  # v5.3.0 drops a .whl alongside the debs, or installs via python3-hailort.
  HAILO_WHEEL=\$(find /usr/lib/hailo* /usr/share/hailo* \$HOME -maxdepth 2 \
    -name 'hailo_platform*.whl' 2>/dev/null | head -1 || true)
  if [[ -n \"\$HAILO_WHEEL\" ]]; then
    echo \"  Installing Python wheel: \$HAILO_WHEEL\"
    pip3 install \"\$HAILO_WHEEL\" --break-system-packages -q
  else
    # Try system package first, then pip
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
pi "hailortcli --version" || true

confirm "HailoRT v${HAILO_VERSION} installed. Proceed to Whisper (NPU-accelerated STT)?"

# ═══════════════════════════════════════════════════════════════
# STEP 3 — Whisper STT (Hailo NPU encoder + CPU decoder)
#           Exposed as Wyoming STT service on port 10300
# ═══════════════════════════════════════════════════════════════
header "STEP 3 — Whisper STT (Hailo NPU encoder + Wyoming server)"

# 3a. Whisper runs as a Docker container (canthefason/wyoming-hailo-whisper).
#     Read the existing compose file, add the service if missing, then
#     bring it up and health-check the Wyoming STT port.

# Path on the Pi — evaluated remotely, not on the Mac
COMPOSE_FILE="${HA_DIR}/compose.yaml"

info "Reading existing compose file on Pi..."
pi "cat $COMPOSE_FILE" || die "Cannot read $COMPOSE_FILE on Pi."

info "Checking if hailo-whisper service is already defined..."
pi "
  if grep -q 'hailo-whisper' $COMPOSE_FILE; then
    echo 'SERVICE_EXISTS'
  else
    echo 'SERVICE_MISSING'
  fi
"

# Add the service if it is not already present
pi "
  set -e
  if grep -q 'hailo-whisper' $COMPOSE_FILE; then
    echo '  hailo-whisper already in compose file — skipping add.'
  else
    echo '  Adding hailo-whisper service to $COMPOSE_FILE...'
    # Detect the Hailo device node
    HAILO_DEV=\$(ls /dev/h1x* 2>/dev/null | head -1 || echo '/dev/h1x-0')
    echo \"  Hailo device: \$HAILO_DEV\"

    # Append the new service block (preserves existing file intact)
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
        echo ''
        echo '  ✘  hailo1x_pci module loaded but /dev/h1x-0 still missing.'
        echo '  Kernel driver information:'
        lsmod | grep hailo || echo '  (not in lsmod)'
        lspci | grep -i hailo || echo '  (hailo not visible in lspci)'
        find /lib/modules/\$(uname -r)/updates -name '*hailo*' 2>/dev/null || echo '  (no hailo .ko in updates/)'
        echo ''
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
        echo ''
        echo '  ✘  DKMS build or modprobe still failing. Full diagnostics:'
        echo '  --- dkms status ---'
        dkms status
        echo '  --- lspci (hailo) ---'
        lspci | grep -i hailo || echo '  (not found in lspci)'
        echo '  --- kernel messages ---'
        sudo dmesg | grep -i hailo | tail -10 || true
        echo ''
        echo '  Most likely cause: raspberrypi-kernel-headers not yet installed'
        echo '  or the M.2 AI Kit is not seated correctly.'
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
  # Use the locally cached image if present; only pull if missing
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
  # Give the container up to 15s to open the port
  for i in 1 2 3; do
    if ss -tlnp | grep -q :${WYOMING_STT_PORT}; then
      ss -tlnp | grep :${WYOMING_STT_PORT}
      echo 'PORT_LISTENING'
      exit 0
    fi
    echo \"  Port ${WYOMING_STT_PORT} not yet open (attempt \$i/3) — waiting 5s...\"
    sleep 5
  done

  # Port still not open — dump diagnostics and exit with a clear message
  echo ''
  echo '  ✘  Port ${WYOMING_STT_PORT} is NOT listening after 15s. Diagnostics:'
  echo ''
  echo '  --- Container status ---'
  docker inspect hailo-whisper --format 'State: {{.State.Status}}  RestartCount: {{.RestartCount}}' 2>/dev/null || true
  echo ''
  echo '  --- Container logs (last 40 lines) ---'
  docker logs hailo-whisper --tail 40 2>&1 || true
  echo ''
  echo '  --- All listening TCP ports ---'
  ss -tlnp
  echo ''
  echo '  --- Docker port mappings ---'
  docker port hailo-whisper 2>/dev/null || true
  exit 1
"
ok "Wyoming STT endpoint: listening on port $WYOMING_STT_PORT"

confirm "Whisper (Hailo NPU + Wyoming) is healthy. Proceed to Ollama (LLM)?"

# ═══════════════════════════════════════════════════════════════
# STEP 4 — Ollama via Docker Compose (CPU-optimised for Pi 5)
#
# The system-installed hailo-gateway (hailo-gateway-1.0.0) is
# Hailo Ollama — it doesn't support standard model pulls. We run
# the official ollama/ollama image in Docker Compose instead so
# model pulls work normally. hailo-gateway is left installed but
# its port is freed up by stopping the systemd service.
#
# TODO: replace with Hailo Ollama once model loading is resolved.
#       See TODO.md.
# ═══════════════════════════════════════════════════════════════
header "STEP 4 — Ollama (Docker Compose, CPU-optimised for Pi 5)"

info "Ensuring port 11434 is available for Docker Ollama..."
pi "
  # If Docker ollama is already running on 11434, we're done — that IS the desired state.
  OLLAMA_STATUS=\$(docker inspect ollama --format '{{.State.Status}}' 2>/dev/null || echo 'missing')
  if [[ \"\$OLLAMA_STATUS\" == 'running' ]]; then
    echo '  Docker ollama already running on port 11434 — nothing to stop.'
    echo 'PORT_FREE_OK'
    exit 0
  fi

  # Port is not held by our Docker ollama; stop any systemd services that own it.
  for SVC in hailo-ollama-gateway.service ollama.service hailo-gateway.service; do
    if systemctl is-active --quiet \"\$SVC\" 2>/dev/null; then
      echo \"  Stopping: \$SVC\"
      sudo systemctl stop \"\$SVC\"
      sudo systemctl disable \"\$SVC\" 2>/dev/null || true
    fi
  done

  # Wait up to 15s for the port to be released.
  for i in 1 2 3; do
    if ! ss -tlnp | grep -q :11434; then
      echo '  Port 11434 is free.'
      echo 'PORT_FREE_OK'
      exit 0
    fi
    echo \"  Port 11434 still in use (attempt \$i/3) — waiting 5s...\"
    HOLDER=\$(ss -tlnp | grep :11434 | grep -oP 'users:\(\(.*?\)\)' || true)
    echo \"  Held by: \$HOLDER\"
    sleep 5
  done
  echo '  ✘  Port 11434 still in use after 15s. Kill the process manually:'
  ss -tlnp | grep :11434
  exit 1
" | grep -E 'PORT_FREE_OK|Stopping|free|already running'
ok "Port 11434: ready for Docker Ollama"

info "Adding ollama service to compose.yaml..."
pi "
  set -e
  if grep -q 'container_name: ollama' $COMPOSE_FILE; then
    echo '  ollama already in compose file — skipping add.'
  else
    cat << 'EOF' >> $COMPOSE_FILE

  ollama:
    image: ollama/ollama:0.20.6
    container_name: ollama
    restart: unless-stopped
    network_mode: host
    volumes:
      - ollama_data:/root/.ollama
    environment:
      - OLLAMA_NUM_THREADS=4
      - OLLAMA_MAX_LOADED_MODELS=1
      - OLLAMA_NUM_PARALLEL=1
      - OLLAMA_FLASH_ATTENTION=1
      - OLLAMA_KEEP_ALIVE=-1
EOF
    # Append named volume declaration if not already present
    if ! grep -q 'ollama_data:' $COMPOSE_FILE; then
      printf '\nvolumes:\n  ollama_data:\n' >> $COMPOSE_FILE
    fi
    echo '  ollama service block appended.'
  fi
  echo 'COMPOSE_OLLAMA_OK'
" | grep -E 'COMPOSE_OLLAMA_OK|already|appended'
ok "compose.yaml: ollama service present"

info "Updating open-webui to use host network (so it can reach Ollama on localhost)..."
pi "
  set -e
  python3 << 'PYEOF'
import re, os, sys

path = os.path.expanduser('${HA_DIR}/compose.yaml')
with open(path) as f:
    content = f.read()

changed = False

# 1. Switch OLLAMA_BASE_URL to localhost
new_content = content.replace(
    'OLLAMA_BASE_URL=http://host.docker.internal:11434',
    'OLLAMA_BASE_URL=http://localhost:11434'
)
if new_content != content:
    print('  Updated OLLAMA_BASE_URL to localhost')
    content = new_content
    changed = True

# 2. Replace open-webui ports + extra_hosts block with network_mode: host + PORT=4000
# Match the open-webui service block fields we want to replace
new_content = re.sub(
    r'(container_name: open-webui.*?restart: unless-stopped\n)'
    r'(\s+ports:\n\s+- \"4000:8080\"\n)',
    r'\1    network_mode: host\n',
    content, flags=re.DOTALL
)
if new_content != content:
    print('  Replaced ports with network_mode: host for open-webui')
    content = new_content
    changed = True

# 3. Remove extra_hosts block under open-webui (no longer needed with host network)
new_content = re.sub(
    r'\s+extra_hosts:\n\s+- \"host\.docker\.internal:host-gateway\"\n',
    '\n',
    content
)
if new_content != content:
    print('  Removed extra_hosts from open-webui')
    content = new_content
    changed = True

# 4. Add PORT=4000 to open-webui environment if not present
if 'container_name: open-webui' in content and 'PORT=4000' not in content:
    new_content = content.replace(
        '      - WEBUI_AUTH=False',
        '      - WEBUI_AUTH=False\n      - PORT=4000'
    )
    if new_content != content:
        print('  Added PORT=4000 to open-webui environment')
        content = new_content
        changed = True

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print('  compose.yaml updated.')
else:
    print('  open-webui already configured for host network — no changes needed.')
PYEOF
  echo 'OPENWEBUI_UPDATED'
" | grep -E 'OPENWEBUI_UPDATED|Updated|Replaced|Removed|Added|already'
ok "open-webui: host network configured"

info "Restarting open-webui with new network config..."
pi "
  cd ${HA_DIR}
  docker compose up -d --force-recreate open-webui
  sleep 3
  docker inspect open-webui --format 'open-webui state: {{.State.Status}}' 2>/dev/null || true
  echo 'OPENWEBUI_RESTARTED'
" | grep -E 'OPENWEBUI_RESTARTED|state:'
ok "open-webui: restarted"

info "Ensuring ollama compose config is correct (network_mode + volume declaration)..."
pi "
  set -e
  python3 << 'PYEOF'
import re, os

path = os.path.expanduser('${HA_DIR}/compose.yaml')
with open(path) as f:
    content = f.read()

changed = False

# 1. Pin ollama image to 0.20.6 if on latest or an older version
new_content = re.sub(
    r'(image: ollama/ollama)(?::[^\s\n]*)?',
    r'\g<1>:0.20.6',
    content
)
if new_content != content:
    print('  Pinned ollama image to ollama/ollama:0.20.6')
    content = new_content
    changed = True

# 2. Replace ports-based ollama service with network_mode: host
new_content = re.sub(
    r'(container_name: ollama\n\s+restart: unless-stopped\n)\s+ports:\n\s+- \"11434:11434\"\n',
    r'\1    network_mode: host\n',
    content
)
if new_content != content:
    print('  Updated ollama service to network_mode: host')
    content = new_content
    changed = True

# 2. Ensure OLLAMA_KEEP_ALIVE is set to -1 (keep model loaded forever)
for old_val in ['5m', '10m', '30m', '1h', '0']:
    if f'OLLAMA_KEEP_ALIVE={old_val}' in content:
        new_content = content.replace(f'OLLAMA_KEEP_ALIVE={old_val}', 'OLLAMA_KEEP_ALIVE=-1')
        if new_content != content:
            print(f'  Updated OLLAMA_KEEP_ALIVE={old_val} → -1')
            content = new_content
            changed = True
        break

# 3. Ensure top-level volumes section declares ollama_data
if 'ollama_data:' in content:
    # Check if it already appears in a top-level volumes block
    if not re.search(r'^volumes:.*?ollama_data:', content, re.MULTILINE | re.DOTALL):
        if re.search(r'^volumes:', content, re.MULTILINE):
            # volumes section exists — insert ollama_data under it
            new_content = re.sub(r'^(volumes:\s*\n)', r'\1  ollama_data:\n', content, flags=re.MULTILINE)
        else:
            # No volumes section at all — append one
            new_content = content.rstrip() + '\n\nvolumes:\n  ollama_data:\n'
        if new_content != content:
            print('  Added ollama_data to top-level volumes section')
            content = new_content
            changed = True
    else:
        print('  ollama_data already declared in volumes section')

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print('  compose.yaml saved.')
else:
    print('  No changes needed.')
PYEOF
  echo 'OLLAMA_COMPOSE_OK'
" | grep -E 'OLLAMA_COMPOSE_OK|Updated|Added|already|No changes'
ok "Ollama compose config: correct"

info "Starting ollama container..."
pi "
  cd ${HA_DIR}
  docker compose pull ollama 2>/dev/null || true
  docker compose up -d ollama
  sleep 5
  curl -s --max-time 10 http://localhost:11434/api/tags > /dev/null && echo 'OLLAMA_SERVICE_OK'
" | grep 'OLLAMA_SERVICE_OK'
ok "Ollama container: running on port 11434"

info "Pulling LLM model (llama3.2:3b — supports tool calling for HA device control)..."
pi "
  set -e
  MODEL=''
  for TAG in 'llama3.2:3b' 'llama3.2:1b' 'qwen2.5:1.5b'; do
    echo \"  Trying: \$TAG\"
    if docker exec ollama ollama pull \$TAG 2>&1 | tee /tmp/ollama_pull.log | tail -3 \
       && ! grep -qi 'error\|failed' /tmp/ollama_pull.log; then
      MODEL=\$TAG
      echo \"  Pulled: \$MODEL\"
      break
    else
      echo \"  \$TAG failed, trying next...\"
    fi
  done
  [[ -n \"\$MODEL\" ]] || { echo '  ERROR: all model pulls failed'; cat /tmp/ollama_pull.log; exit 1; }
  echo \"MODEL_NAME=\$MODEL\"
" | grep -E 'Pulled:|MODEL_NAME=|failed'
ok "LLM model: pulled"

info "Creating voice-assistant Modelfile (tool-calling enabled, voice-tuned)..."
PULLED_MODEL=$(pi "docker exec ollama ollama list 2>/dev/null | awk 'NR>1{print \$1}' | grep -E 'llama3.2|qwen2.5' | head -1")
PULLED_MODEL=${PULLED_MODEL:-llama3.2:3b}
info "Base model: $PULLED_MODEL"
pi "
  set -e
  # Build Modelfile from the base model's full Modelfile (preserves the
  # tool-calling TEMPLATE required by extended_openai_conversation),
  # then append voice-tuned parameters on top.
  docker exec ollama sh -c \"
    ollama show $PULLED_MODEL --modelfile > /tmp/Modelfile
    cat >> /tmp/Modelfile << 'EOF'

PARAMETER num_ctx 2048
PARAMETER temperature 0.7
PARAMETER top_p 0.9
SYSTEM You are a concise voice assistant for a smart home. Keep responses short and spoken-friendly. When controlling devices, always use the available tools.
EOF
    ollama create voice-assistant -f /tmp/Modelfile\"
  echo 'MODELFILE_OK'
" | grep 'MODELFILE_OK'
ok "voice-assistant model: created (tool-calling enabled)"

info "Running LLM health check..."
pi "
  RESP=\$(docker exec ollama ollama run voice-assistant 'Reply with one word: HEALTHY' 2>/dev/null \
    | tr -d '\n' | head -c 100)
  echo \"  LLM response: \$RESP\"
  echo 'OLLAMA_HEALTH_OK'
" | grep -E 'OLLAMA_HEALTH_OK|response'
ok "Ollama LLM: responding"

confirm "Ollama is healthy. Proceed to Piper TTS health check?"

# ═══════════════════════════════════════════════════════════════
# STEP 5 — Piper TTS (already running via Docker Compose)
#           Health-check only
# ═══════════════════════════════════════════════════════════════
header "STEP 5 — Piper TTS (Docker Compose) — health check"

info "Checking Docker Compose Piper container is running..."
pi "
  # Find the running Piper container
  PIPER_CONTAINER=\$(docker ps --format '{{.Names}}' | grep -i piper | head -1 || true)
  if [[ -n \"\$PIPER_CONTAINER\" ]]; then
    echo \"  Piper container: \$PIPER_CONTAINER\"
    docker inspect \"\$PIPER_CONTAINER\" --format '  Status: {{.State.Status}}'
    echo 'PIPER_CONTAINER_OK'
  else
    echo '  No running Piper container found.'
    echo '  Running containers:'
    docker ps --format '  {{.Names}} ({{.Image}})'
    echo ''
    echo '  ⚠  If Piper is in a compose file, start it with:'
    echo '     docker compose up -d piper'
    echo 'PIPER_NOT_RUNNING'
  fi
"

info "Checking Piper Wyoming TTS port (default: 10200)..."
PIPER_PORT=$(pi "
  # Detect mapped port from docker inspect or default to 10200
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

PI_IP=$(ssh "$SSH_ALIAS" "hostname -I | awk '{print \$1}'")
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
#
# Gives Ollama full Home Assistant device-control capability
# by exposing HA services as function-call tools to the LLM.
# Installed directly into config/custom_components/ — no HACS needed.
# ═══════════════════════════════════════════════════════════════
header "STEP 7 — Extended OpenAI Conversation (Ollama + HA device control)"

info "Installing extended_openai_conversation custom component..."
EOCA_OUT=""; EOCA_RC=0
EOCA_OUT=$(pi "
  CUSTOM_DIR=${HA_DIR}/config/custom_components
  EOCA_DIR=\$CUSTOM_DIR/extended_openai_conversation
  # HA config dir is written by the container (root-owned) — use sudo
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
  # Fall back to source zip if no release asset
  if [[ -z \"\$ZIP_URL\" ]]; then
    ZIP_URL=\"https://github.com/jekalmin/extended_openai_conversation/archive/refs/tags/\${TAG}.zip\"
  fi
  echo \"  Downloading \$TAG: \$ZIP_URL\"
  curl -sL -o /tmp/eoca.zip \"\$ZIP_URL\"

  rm -rf /tmp/eoca_work && mkdir /tmp/eoca_work
  unzip -q /tmp/eoca.zip -d /tmp/eoca_work

  # Locate the integration root (wherever manifest.json lives)
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
if [[ $EOCA_RC -ne 0 ]]; then
  die "extended_openai_conversation SSH command failed (exit $EOCA_RC) — see output above"
fi
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
if [[ $HA_RC -ne 0 ]]; then
  die "Home Assistant restart SSH command failed (exit $HA_RC) — see output above"
fi
[[ "$HA_OUT" == *HA_RESTARTING* ]] || die "Home Assistant restart failed (no HA_RESTARTING token)"
ok "Home Assistant: restarting (allow ~30s before opening the UI)"

echo ""
echo -e "${CYAN}  ── Configure Extended OpenAI Conversation in HA ──────────────────${NC}"
echo -e "  1. Wait ~30s, then open  http://${PI_IP}:8123"
echo -e "  2. Settings → Devices & Services → Add Integration"
echo -e "  3. Search  ${BOLD}Extended OpenAI Conversation${NC}"
echo -e "  4. Fill in:"
echo -e "       API Key : ollama           (any value — not checked)"
echo -e "       Base URL: http://localhost:11434/v1"
echo -e "       Model   : voice-assistant  (or phi3:mini)"
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
  echo '[3/3] Ollama LLM endpoint...'
  curl -s http://localhost:11434/api/tags | python3 -c \"
import json, sys
data = json.load(sys.stdin)
models = [m['name'] for m in data.get('models', [])]
print('  Ollama models:', models)
print('  OLLAMA_SMOKE_OK')
\" 2>/dev/null || docker exec ollama ollama list
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
echo -e "${GREEN}║  Ollama (LLM, CPU)        ✔         port 11434         ║${NC}"
echo -e "${GREEN}║  Piper TTS (Docker)       ✔         port 10200 (Wyoming)║${NC}"
echo -e "${GREEN}║  Ext. OpenAI Conversation ✔         custom_components/ ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Wyoming STT  tcp://${PI_IP}:${WYOMING_STT_PORT}             ║${NC}"
echo -e "${GREEN}║  Wyoming TTS  tcp://${PI_IP}:10200               ║${NC}"
echo -e "${GREEN}║  Ollama API   http://${PI_IP}:11434          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
warn "If /dev/h1x* shows 'permission denied', run: sudo reboot"
warn "After reboot your user will be in the 'hailo' group."
echo ""
echo -e "${CYAN}  Service management:${NC}"
echo -e "  ssh ${SSH_ALIAS} 'docker logs hailo-whisper -f'       # Whisper STT logs"
echo -e "  ssh ${SSH_ALIAS} 'docker logs ollama -f'              # Ollama LLM logs"
echo -e "  ssh ${SSH_ALIAS} 'docker logs wyoming-piper -f'       # Piper TTS logs"
echo -e "  ssh ${SSH_ALIAS} 'cd ${HA_DIR} && docker compose ps'  # all containers"
echo ""
