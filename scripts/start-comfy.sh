#!/usr/bin/env bash
# Launch the local ComfyUI workspace with the 10Eros LikenessGuide I2V workflow
# pre-staged in the user workflows folder so it shows up in the sidebar.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_NAME="10Eros_10SNodes_LikenessGuideHelper_I2V_v3.2.json"
SRC_WORKFLOW="$REPO_ROOT/comfyui/$WORKFLOW_NAME"
COMFY_HOME="${COMFY_HOME:-$HOME/comfyui}"
DEST_DIR="$COMFY_HOME/user/default/workflows"
LISTEN="${COMFY_LISTEN:-127.0.0.1}"
PORT="${COMFY_PORT:-8188}"

if [[ ! -f "$SRC_WORKFLOW" ]]; then
  echo "ERROR: workflow not found at $SRC_WORKFLOW" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp -f "$SRC_WORKFLOW" "$DEST_DIR/"
echo "Staged workflow: $DEST_DIR/$WORKFLOW_NAME"

comfy --workspace "$COMFY_HOME" launch --background -- --listen "$LISTEN" --port "$PORT"
echo "ComfyUI: http://$LISTEN:$PORT"
echo "Workflow file is in the Workflows sidebar as: $WORKFLOW_NAME"
