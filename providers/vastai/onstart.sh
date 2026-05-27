#!/usr/bin/env bash
# providers/vastai/onstart.sh
#
# VastAI --onstart-cmd bootstrap. Self-contained: this script clones the
# provisioner framework (this repo) AND the stack repo INDEPENDENTLY — no
# recursive submodule descent. The submodule layout that ships in the stack
# repo is purely a local-dev convenience and intentionally NOT used at runtime,
# because nested submodule clones can't reuse the top-level GH_TOKEN.
#
# Usage (wire this into VastAI's --onstart-cmd):
#   bash <(curl -fsSL https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/vastai/onstart.sh)
#
# Required env (from --env at instance create):
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

set -euo pipefail

# Mirror all output to /workspace/provision.log so the log survives the boot
# even when onstart-cmd output isn't captured by the caller. tee -a is safe
# on re-runs: appends, doesn't truncate.
mkdir -p /workspace
exec > >(tee -a /workspace/provision.log) 2>&1

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
  git clone --branch "$PROVISIONER_BRANCH" "https://github.com/${PROVISIONER_REPO}.git" "$PROVISIONER_DIR"
else
  echo "[onstart] $PROVISIONER_DIR already cloned -- pulling latest"
  git -C "$PROVISIONER_DIR" pull --rebase
fi

# 2. Clone the stack repo (flat -- NO --recurse-submodules; only top-level
#    provisioner-config.sh + comfyui/ are needed at runtime)
if [ ! -d "$STACK_DIR/.git" ]; then
  if [ -n "${GH_TOKEN:-}" ]; then
    auth_url="https://${GH_TOKEN}@github.com/${STACK_REPO}.git"
  else
    auth_url="https://github.com/${STACK_REPO}.git"
  fi
  git clone --branch "$STACK_BRANCH" "$auth_url" "$STACK_DIR"
else
  echo "[onstart] $STACK_DIR already cloned -- pulling latest"
  git -C "$STACK_DIR" pull --rebase
fi

# 3. Verify the stack ships the contract
PROVISIONER_CONFIG="$STACK_DIR/provisioner-config.sh"
if [ ! -f "$PROVISIONER_CONFIG" ]; then
  echo "[onstart] FATAL: $PROVISIONER_CONFIG not found in stack repo" >&2
  echo "[onstart] STACK_REPO must contain provisioner-config.sh at its root." >&2
  exit 1
fi

# 4. Run the provisioner with explicit, decoupled paths
export PROVISIONER_CONFIG
export WORKFLOWS_SRC_DIR="$STACK_DIR/comfyui"
echo "[onstart] PROVISIONER_CONFIG=$PROVISIONER_CONFIG"
echo "[onstart] WORKFLOWS_SRC_DIR=$WORKFLOWS_SRC_DIR"

bash "$PROVISIONER_DIR/scripts/provision-comfyui.sh"

echo "[onstart] provisioning complete -- ComfyUI should be reachable on the instance's port 18188"
