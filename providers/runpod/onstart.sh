#!/usr/bin/env bash
# providers/runpod/onstart.sh
#
# RunPod pod bootstrap — invoked via the pod's "Container Start Command":
#
#   bash -c "curl -fsSL ${PROVISIONER_URL} | bash"
#
# or equivalently by pointing the Container Start Command field directly
# at this raw GitHub URL. This runs as root on every pod start, including
# resume after suspend.
#
# Self-contained: clones the provisioner framework AND the stack repo
# independently — no recursive submodule descent. The submodule layout
# that may ship inside a stack repo is purely a local-dev convenience
# and is intentionally NOT used at runtime.
#
# Wiring on a RunPod pod (runpodctl create pod ...):
#   --containerStartCommand 'bash -c "curl -fsSL <url-to-this-file> | bash"'
#   --env "HF_TOKEN=hf_xxx"
#   --env "STACK_REPO=owner/your-stack"
#   --env "GH_TOKEN=ghp_xxx"         (private stacks)
#   ...
#
# No portal / Caddy / supervisord here. ComfyUI is launched directly via
# pkill + nohup and writes to /workspace/comfyui.log. The RunPod proxy
# surfaces port 8188 at:
#   https://<pod-id>-8188.proxy.runpod.net
#
# Required env:
#   HF_TOKEN          HuggingFace token (gated models + workflow fallbacks)
#   STACK_REPO        owner/repo containing provisioner-config.sh + comfyui/
#
# Required if STACK_REPO is private:
#   GH_TOKEN          GitHub PAT with read access to STACK_REPO
#
# Optional env:
#   CIVITAI_API_KEY        Civitai token (LoRA downloads — Phase 5 warns if unset)
#   STACK_BRANCH           Stack repo branch (default: main)
#   STACK_DIR              Where to clone the stack (default: /workspace/<basename STACK_REPO>)
#   PROVISIONER_REPO       owner/repo of this framework (default: ismail-kattakath/comfyui-provisioner)
#   PROVISIONER_BRANCH     Framework branch (default: main)
#   PROVISIONER_DIR        Where to clone the framework (default: /workspace/comfyui-provisioner)
#   SKIP_SYSTEM=1 SKIP_NODES=1 SKIP_WORKFLOW=1 SKIP_MODELS=1 SKIP_UPDATE_ALL=1 SKIP_RESTART=1
#
# Optional Syncthing pre-pair (workflow edits mirror to your local folder in
# real time — replaces the deprecated git-push save-workflow helper):
#   SYNCTHING_PEER_DEVICE_ID  Operator's Syncthing device ID (stable across pods).
#                             When set, onstart adds it as a paired peer and
#                             creates a sendonly folder share for the workflows dir.
#                             The peer accepts the share via the pair-syncthing skill.
#                             Skipped if unset — a note is printed reminding the
#                             operator to run /pair-syncthing manually post-boot.
#   SYNCTHING_PEER_NAME       Friendly name for the peer (default: local-peer)
#   SYNCTHING_FOLDER_ID       Folder ID, must match peer (default: comfyui-workflows)
#   SYNCTHING_FOLDER_LABEL    Display label (default: "ComfyUI Workflows")

set -euo pipefail

trap 'echo "[onstart] FAILED at line $LINENO — $(date -u +%H:%M:%SZ)"; exit 1' ERR

# Mirror all output to /workspace/provision.log so the log survives the boot
# even when the container start command output isn't captured by the caller.
# tee -a is safe on re-runs: appends, never truncates.
mkdir -p /workspace
exec > >(tee -a /workspace/provision.log) 2>&1

echo "[onstart] === RunPod ComfyUI provisioner started — $(date -u) ==="

: "${HF_TOKEN:?HF_TOKEN must be set via --env}"
: "${STACK_REPO:?STACK_REPO must be set via --env (format: owner/repo)}"

STACK_BRANCH="${STACK_BRANCH:-main}"
STACK_DIR="${STACK_DIR:-/workspace/$(basename "$STACK_REPO")}"
PROVISIONER_REPO="${PROVISIONER_REPO:-ismail-kattakath/comfyui-provisioner}"
PROVISIONER_BRANCH="${PROVISIONER_BRANCH:-main}"
PROVISIONER_DIR="${PROVISIONER_DIR:-/workspace/comfyui-provisioner}"

echo "[onstart] STACK_REPO=$STACK_REPO  STACK_DIR=$STACK_DIR  STACK_BRANCH=$STACK_BRANCH"
echo "[onstart] PROVISIONER_REPO=$PROVISIONER_REPO  PROVISIONER_DIR=$PROVISIONER_DIR  PROVISIONER_BRANCH=$PROVISIONER_BRANCH"

# 1. Clone the public provisioner framework (no auth needed; flat clone)
if [ ! -d "$PROVISIONER_DIR/.git" ]; then
  git clone --branch "$PROVISIONER_BRANCH" \
    "https://github.com/${PROVISIONER_REPO}.git" "$PROVISIONER_DIR"
else
  echo "[onstart] $PROVISIONER_DIR already cloned — pulling latest"
  git -C "$PROVISIONER_DIR" pull --rebase
fi

# 2. Clone the stack repo (flat — NO --recurse-submodules; only top-level
#    provisioner-config.sh + comfyui/ are needed at runtime)
if [ ! -d "$STACK_DIR/.git" ]; then
  if [ -n "${GH_TOKEN:-}" ]; then
    auth_url="https://${GH_TOKEN}@github.com/${STACK_REPO}.git"
  else
    auth_url="https://github.com/${STACK_REPO}.git"
  fi
  git clone --branch "$STACK_BRANCH" "$auth_url" "$STACK_DIR"
else
  echo "[onstart] $STACK_DIR already cloned — pulling latest"
  git -C "$STACK_DIR" pull --rebase
fi

# 3. Verify the stack ships the required contract
PROVISIONER_CONFIG="$STACK_DIR/provisioner-config.sh"
if [ ! -f "$PROVISIONER_CONFIG" ]; then
  echo "[onstart] FATAL: $PROVISIONER_CONFIG not found in stack repo" >&2
  echo "[onstart] STACK_REPO must contain provisioner-config.sh at its root." >&2
  exit 1
fi

# 4. Wire explicit, decoupled paths for the provisioner
export PROVISIONER_CONFIG
export WORKFLOWS_SRC_DIR="$STACK_DIR/comfyui"
echo "[onstart] PROVISIONER_CONFIG=$PROVISIONER_CONFIG"
echo "[onstart] WORKFLOWS_SRC_DIR=$WORKFLOWS_SRC_DIR"

# 4b. Mirror HF_TOKEN to non-standard env-var aliases that some ComfyUI
#     custom_nodes read directly (instead of using huggingface_hub's
#     standard HF_TOKEN). Setting both known aliases is cheap.
#       HUGGINGFACE_TOKEN   — huchukato/ComfyUI-HuggingFace (source code)
#       HUGGINGFACE_API_KEY — huchukato/ComfyUI-HuggingFace (README claims)
export HUGGINGFACE_TOKEN="${HF_TOKEN}"
export HUGGINGFACE_API_KEY="${HF_TOKEN}"

# 5. Persist tokens + config to /workspace/.provisioner.env so the operator
#    can re-run the provisioner from an interactive SSH session. RunPod does
#    NOT export the container start env to SSH shells, so without this file
#    a manual `bash scripts/provision-comfyui.sh` aborts with
#    "HF_TOKEN must be set in the environment".
#    Values are written with `printf %q` so they round-trip safely when sourced.
#    Permissions: chmod 600 — never world-readable.
(
  umask 077
  {
    printf "# Auto-generated by providers/runpod/onstart.sh -- do not edit.\n"
    printf "# Source this file in an SSH session before re-running the\n"
    printf "# provisioner manually:\n"
    printf "#   source /workspace/.provisioner.env\n"
    printf "#   bash %s/scripts/provision-comfyui.sh\n" "$PROVISIONER_DIR"
    printf "# Or use the wrapper: bash /workspace/reprovision.sh\n"
    printf "export HF_TOKEN=%q\n"             "${HF_TOKEN}"
    printf "export HUGGINGFACE_TOKEN=%q\n"    "${HF_TOKEN}"
    printf "export HUGGINGFACE_API_KEY=%q\n"  "${HF_TOKEN}"
    printf "export CIVITAI_API_KEY=%q\n"      "${CIVITAI_API_KEY:-}"
    printf "export GH_TOKEN=%q\n"             "${GH_TOKEN:-}"
    printf "export STACK_REPO=%q\n"           "${STACK_REPO}"
    printf "export STACK_BRANCH=%q\n"         "${STACK_BRANCH}"
    printf "export STACK_DIR=%q\n"            "${STACK_DIR}"
    printf "export PROVISIONER_REPO=%q\n"     "${PROVISIONER_REPO}"
    printf "export PROVISIONER_BRANCH=%q\n"   "${PROVISIONER_BRANCH}"
    printf "export PROVISIONER_DIR=%q\n"      "${PROVISIONER_DIR}"
    printf "export PROVISIONER_CONFIG=%q\n"   "${PROVISIONER_CONFIG}"
    printf "export WORKFLOWS_SRC_DIR=%q\n"    "${WORKFLOWS_SRC_DIR}"
    printf "export SYNCTHING_PEER_DEVICE_ID=%q\n" "${SYNCTHING_PEER_DEVICE_ID:-}"
    printf "export SYNCTHING_PEER_NAME=%q\n"      "${SYNCTHING_PEER_NAME:-}"
    printf "export SYNCTHING_FOLDER_ID=%q\n"      "${SYNCTHING_FOLDER_ID:-}"
    printf "export SYNCTHING_FOLDER_LABEL=%q\n"   "${SYNCTHING_FOLDER_LABEL:-}"
  } > /workspace/.provisioner.env
)
chmod 600 /workspace/.provisioner.env
echo "[onstart] wrote /workspace/.provisioner.env (chmod 600)"

# Source it from interactive SSH shells so re-running the provisioner is
# friction-free. Only append the line once (idempotent on re-boots).
if [ -f /root/.bashrc ] && ! grep -qF "/workspace/.provisioner.env" /root/.bashrc; then
  printf "\n# Auto-load provisioner env (written by comfyui-provisioner onstart.sh)\n[ -f /workspace/.provisioner.env ] && source /workspace/.provisioner.env\n" \
    >> /root/.bashrc
  echo "[onstart] appended provisioner-env loader to /root/.bashrc"
fi

# Drop a one-shot re-provisioning wrapper so iterating is a single command.
cat > /workspace/reprovision.sh <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Re-run the comfyui-provisioner against the current stack.
# Sources /workspace/.provisioner.env (written by onstart.sh at boot) so
# the SSH session has the same env the original boot had.
set -euo pipefail
if [ ! -f /workspace/.provisioner.env ]; then
  echo "ERROR: /workspace/.provisioner.env not found." >&2
  echo "       Either onstart.sh hasn't completed yet, or this is not a" >&2
  echo "       RunPod pod bootstrapped by comfyui-provisioner." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /workspace/.provisioner.env
# Pull latest framework + stack so the re-run picks up any pushed fixes.
if [ -d "${PROVISIONER_DIR}/.git" ]; then
  git -C "${PROVISIONER_DIR}" pull --rebase --quiet || true
fi
if [ -d "${STACK_DIR}/.git" ]; then
  git -C "${STACK_DIR}" pull --rebase --quiet || true
fi
exec bash "${PROVISIONER_DIR}/scripts/provision-comfyui.sh" "$@"
WRAPPER_EOF
chmod +x /workspace/reprovision.sh
echo "[onstart] wrote /workspace/reprovision.sh"

# Run the provisioner (7 phases: preflight → system → tokens → nodes →
# workflows → models → manager-update → restart).
# Phase 7 (restart) is a no-op on RunPod because HAS_SUPERVISOR=0 — we
# handle the ComfyUI launch ourselves below.
bash "$PROVISIONER_DIR/scripts/provision-comfyui.sh"

# --- Launch ComfyUI -------------------------------------------------------
# No supervisord on this image. Kill any previous main.py left over from
# a prior boot (e.g., after suspend/resume), then launch fresh.
# Logs go to /workspace/comfyui.log (accessible via SSH).
#
# Race note: pkill fires before the fresh launch to avoid two main.py
# processes competing for port 8188. The 2s sleep lets the old process
# finish its teardown before we bind the port.
echo "[onstart] (re)starting ComfyUI on port 8188 ..."
pkill -f "main.py.*--port 8188" 2>/dev/null || true
sleep 2

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
if [ ! -f "$COMFYUI_DIR/main.py" ]; then
  echo "[onstart] WARNING: $COMFYUI_DIR/main.py not found." \
       "ComfyUI may not be installed — check the Docker image." >&2
else
  cd "$COMFYUI_DIR"
  # --port 8188         — RunPod proxies this port directly (no Caddy)
  # --listen 0.0.0.0    — required for RunPod's HTTP proxy to reach it
  # --enable-cors-header — allows browser clients via the proxy origin
  # --enable-manager    — keeps ComfyUI-Manager usable
  nohup python main.py \
    --port 8188 \
    --listen 0.0.0.0 \
    --enable-cors-header \
    --enable-manager \
    > /workspace/comfyui.log 2>&1 &
  echo "[onstart] ComfyUI launched (PID $!) — tail /workspace/comfyui.log"
fi

# --- Syncthing folder sync -----------------------------------------------
# Workflow edits mirror to the operator's local folder in real time.
# Syncthing must be installed in the Docker image for this to work.
# The pair-syncthing skill handles the laptop-side acceptance.
echo "[onstart] === Syncthing folder sync setup ==="

if ! command -v syncthing >/dev/null 2>&1; then
  echo "[onstart] syncthing not found in PATH — skipping auto-pair."
  echo "[onstart]   To use Syncthing, install it in the Docker image or via apt."
else
  ST_HOME="${HOME}/.config/syncthing"
  ST_GUI_ADDR="127.0.0.1:8384"
  mkdir -p "$ST_HOME"

  # Start syncthing as a background daemon if not already running
  if ! pgrep -x syncthing >/dev/null 2>&1; then
    nohup syncthing serve \
      --gui-address="$ST_GUI_ADDR" \
      --home="$ST_HOME" \
      --no-browser \
      > /workspace/syncthing.log 2>&1 &
    echo "[onstart] syncthing daemon started (PID $!)"
    for i in $(seq 1 30); do
      if curl -sf "http://${ST_GUI_ADDR}/rest/system/status" >/dev/null 2>&1; then
        echo "[onstart] syncthing API up after ${i}s"
        break
      fi
      sleep 1
    done
  fi

  # Extract API key from config.xml (written on first start)
  ST_API_KEY=""
  if [ -f "$ST_HOME/config.xml" ]; then
    ST_API_KEY=$(grep -oP '(?<=<apikey>)[^<]+' "$ST_HOME/config.xml" | head -1 || true)
  fi

  ST_CLI=(syncthing cli --gui-address="$ST_GUI_ADDR" --gui-apikey="$ST_API_KEY")

  # Always log this pod's Syncthing device ID for reference
  INSTANCE_DEV_ID=$("${ST_CLI[@]}" show system status 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('myID',''))" \
    2>/dev/null || true)
  if [ -n "$INSTANCE_DEV_ID" ]; then
    echo "[onstart] syncthing instance device ID: $INSTANCE_DEV_ID"
  fi

  if [ -n "${SYNCTHING_PEER_DEVICE_ID:-}" ]; then
    ST_PEER_NAME="${SYNCTHING_PEER_NAME:-local-peer}"
    ST_FOLDER_ID="${SYNCTHING_FOLDER_ID:-comfyui-workflows}"
    ST_FOLDER_LABEL="${SYNCTHING_FOLDER_LABEL:-ComfyUI Workflows}"
    ST_FOLDER_PATH="${COMFYUI_DIR:-/workspace/ComfyUI}/user/default/workflows"
    mkdir -p "$ST_FOLDER_PATH"

    if ! "${ST_CLI[@]}" config devices list 2>/dev/null | grep -qF "$SYNCTHING_PEER_DEVICE_ID"; then
      "${ST_CLI[@]}" config devices add \
        --device-id "$SYNCTHING_PEER_DEVICE_ID" \
        --name "$ST_PEER_NAME"
      "${ST_CLI[@]}" config devices "$SYNCTHING_PEER_DEVICE_ID" compression set always
      echo "[onstart] added peer device $SYNCTHING_PEER_DEVICE_ID ($ST_PEER_NAME)"
    fi

    if ! "${ST_CLI[@]}" config folders list 2>/dev/null | grep -qF "$ST_FOLDER_ID"; then
      "${ST_CLI[@]}" config folders add \
        --id "$ST_FOLDER_ID" \
        --label "$ST_FOLDER_LABEL" \
        --path "$ST_FOLDER_PATH" \
        --type sendonly
      echo "[onstart] created sendonly folder share $ST_FOLDER_ID -> $ST_FOLDER_PATH"
    fi

    if ! "${ST_CLI[@]}" config folders "$ST_FOLDER_ID" devices list 2>/dev/null \
        | grep -qF "$SYNCTHING_PEER_DEVICE_ID"; then
      "${ST_CLI[@]}" config folders "$ST_FOLDER_ID" devices add \
        --device-id "$SYNCTHING_PEER_DEVICE_ID"
      echo "[onstart] sharing $ST_FOLDER_ID with $SYNCTHING_PEER_DEVICE_ID"
    fi

    echo "[onstart] syncthing pre-pair complete"
    echo "[onstart]   instance device ID : $INSTANCE_DEV_ID"
    echo "[onstart]   on your laptop, run: /pair-syncthing <pod-id>"
  else
    echo "[onstart] SYNCTHING_PEER_DEVICE_ID unset — syncthing running but no auto-pair."
    echo "[onstart]   To enable: set SYNCTHING_PEER_DEVICE_ID=<laptop-device-id> on pod create."
    echo "[onstart]   Manual pairing: /pair-syncthing <pod-id> (SSH-reads the device ID)"
  fi
fi

echo "[onstart] === provisioning complete === $(date -u)"
echo "[onstart] ComfyUI: https://<pod-id>-8188.proxy.runpod.net"
echo "[onstart] Log:     tail -f /workspace/comfyui.log"
echo "[onstart] Reprovision: bash /workspace/reprovision.sh"
