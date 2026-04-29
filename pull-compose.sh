#!/usr/bin/env bash
# pull-compose.sh — copy compose.yaml from the Pi to this folder
# Override: RPI_HOST, RPI_USER, HA_DIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_ALIAS="${RPI_HOST:-rpi.local}"
RPI_USER="${RPI_USER:-pi}"
HA_DIR="${HA_DIR:-/home/${RPI_USER}/homeassistant}"
REMOTE_FILE="${HA_DIR}/compose.yaml"
LOCAL_FILE="${SCRIPT_DIR}/compose.yaml"

echo "Pulling compose.yaml from ${SSH_ALIAS}..."
scp "${SSH_ALIAS}:${REMOTE_FILE}" "${LOCAL_FILE}"
echo "Saved → ${LOCAL_FILE}"
