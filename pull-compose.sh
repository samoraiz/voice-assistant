#!/usr/bin/env bash
# pull-compose.sh — copy ~/homeassistant/compose.yaml from hailo-pi to this folder
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_ALIAS="${RPI_HOST:-rpi.local}"
REMOTE_FILE="~/homeassistant/compose.yaml"
LOCAL_FILE="${SCRIPT_DIR}/compose.yaml"

echo "Pulling compose.yaml from ${SSH_ALIAS}..."
scp "${SSH_ALIAS}:${REMOTE_FILE}" "${LOCAL_FILE}"
echo "Saved → ${LOCAL_FILE}"
