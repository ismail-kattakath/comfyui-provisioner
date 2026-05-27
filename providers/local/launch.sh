#!/usr/bin/env bash
# providers/local/launch.sh
#
# Local provisioning + launch for development on macOS / Linux.
# Assumes:
#   - ComfyUI is already installed at $COMFYUI_DIR (default: ~/comfyui)
#   - You have a stack repo with provisioner-config.sh checked out somewhere
#
# Usage:
#   PROVISIONER_CONFIG=/path/to/your/stack/provisioner-config.sh \
#   WORKFLOWS_SRC_DIR=/path/to/your/stack/comfyui \
#   bash providers/local/launch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER_SCRIPT="$SCRIPT_DIR/../../scripts/provision-comfyui.sh"

: "${PROVISIONER_CONFIG:?PROVISIONER_CONFIG must point to the stack provisioner-config.sh}"
: "${COMFYUI_DIR:=$HOME/comfyui}"

if [ ! -d "$COMFYUI_DIR" ]; then
  echo "ERROR: COMFYUI_DIR=$COMFYUI_DIR does not exist" >&2
  echo "Install ComfyUI first (see https://github.com/comfyanonymous/ComfyUI)" >&2
  exit 1
fi

# Skip phases that don't make sense locally
export SKIP_SYSTEM="${SKIP_SYSTEM:-1}"     # no apt-get on macOS
export SKIP_RESTART="${SKIP_RESTART:-1}"   # no supervisorctl locally
export COMFYUI_DIR

bash "$PROVISIONER_SCRIPT"

echo
echo "Done. To launch ComfyUI now:"
echo "  comfy --workspace $COMFYUI_DIR launch -- --listen 127.0.0.1 --port 8188"
