#!/usr/bin/env bash
# ============================================================
# 00-setup-ssh.sh — Configure SSH access to the Hailo Pi
# Run this once on your Mac before anything else.
# Usage: bash 00-setup-ssh.sh
# ============================================================
set -euo pipefail

HOST="${RPI_HOST:-rpi.local}"
USER="ctf"
ALIAS="hailo-pi"
KEY="$HOME/.ssh/id_ed25519"
SSH_CONFIG="$HOME/.ssh/config"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✔  $*${NC}"; }
info() { echo -e "${CYAN}  →  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
die()  { echo -e "${RED}  ✘  $*${NC}" >&2; exit 1; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Hailo Pi — SSH Setup (step 0 of 0)     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Key exists? ──────────────────────────────────────────
info "Checking for SSH key at $KEY..."
[[ -f "$KEY" ]] || die "Key not found: $KEY  (run: ssh-keygen -t ed25519)"
[[ -f "${KEY}.pub" ]] || die "Public key not found: ${KEY}.pub"
ok "Key found."

# ── 2. Reachability ─────────────────────────────────────────
info "Pinging $HOST (requires Pi to be on the same network)..."
if ping -c1 -W2 "$HOST" &>/dev/null; then
    ok "$HOST is reachable."
else
    die "$HOST is not reachable. Make sure the Pi is on and on the same network."
fi

# ── 3. ~/.ssh/config entry ──────────────────────────────────
info "Updating ~/.ssh/config..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if grep -q "Host $ALIAS" "$SSH_CONFIG" 2>/dev/null; then
    warn "Entry 'Host $ALIAS' already exists in $SSH_CONFIG — skipping."
else
    cat >> "$SSH_CONFIG" <<EOF

Host $ALIAS
    HostName $HOST
    User $USER
    IdentityFile $KEY
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF
    chmod 600 "$SSH_CONFIG"
    ok "Added 'Host $ALIAS' to $SSH_CONFIG."
fi

# ── 4. Copy public key ──────────────────────────────────────
info "Copying public key to ${USER}@${HOST} (you may be prompted for a password)..."
ssh-copy-id -i "${KEY}.pub" "${USER}@${HOST}" \
    && ok "Public key installed on Pi." \
    || die "ssh-copy-id failed. Is the Pi running and accepting passwords?"

# ── 5. Smoke test ───────────────────────────────────────────
info "Testing passwordless SSH login..."
RESULT=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$ALIAS" "echo OK" 2>&1) || \
    die "SSH test failed: $RESULT"
[[ "$RESULT" == "OK" ]] || die "Unexpected SSH output: $RESULT"
ok "Passwordless SSH is working!"

# ── 6. Show Pi info ─────────────────────────────────────────
info "Quick Pi snapshot:"
ssh "$ALIAS" "uname -a; cat /etc/os-release | grep PRETTY; free -h | grep Mem; df -h / | tail -1"

echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SSH setup complete. Next step:${NC}"
echo -e "${GREEN}  bash 01-install-hailo-voice-assistant.sh${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
