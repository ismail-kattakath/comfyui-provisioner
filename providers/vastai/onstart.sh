#!/usr/bin/env bash
# providers/vastai/onstart.sh
#
# VastAI --onstart-cmd bootstrap. Clones your private stack repo, initializes
# the comfyui-provisioner submodule, then runs the provisioner with your
# stack-specific config sourced.
#
# Usage (one-liner you wire into VastAI's --onstart-cmd):
#   bash <(curl -fsSL https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/vastai/onstart.sh)
#
# Required env (from --env flag at instance create):
#   HF_TOKEN          HuggingFace token (gated models + workflow fallbacks)
#   STACK_REPO        owner/repo of your stack (provides provisioner-config.sh + comfyui/)
#
# Required if STACK_REPO is private:
#   GH_TOKEN          GitHub PAT with read access to STACK_REPO
#
# Optional env:
#   CIVITAI_API_KEY   Civitai token (LoRA downloads — Phase 5 will warn if unset)
#   STACK_BRANCH      default: main
#   STACK_DIR         default: /workspace/$(basename STACK_REPO)
#   SKIP_SYSTEM=1 SKIP_NODES=1 SKIP_WORKFLOW=1 SKIP_MODELS=1 SKIP_UPDATE_ALL=1 SKIP_RESTART=1

set -euo pipefail

: "${HF_TOKEN:?HF_TOKEN must be set via --env}"
: "${STACK_REPO:?STACK_REPO must be set via --env (format: owner/repo)}"

STACK_BRANCH="${STACK_BRANCH:-main}"
STACK_DIR="${STACK_DIR:-/workspace/$(basename "$STACK_REPO")}"

echo "[onstart] STACK_REPO=$STACK_REPO  STACK_BRANCH=$STACK_BRANCH  STACK_DIR=$STACK_DIR"

# 1. Clone the stack repo (auth with GH_TOKEN if private)
if [ ! -d "$STACK_DIR/.git" ]; then
  if [ -n "${GH_TOKEN:-}" ]; then
    auth_url="https://${GH_TOKEN}@github.com/${STACK_REPO}.git"
  else
    auth_url="https://github.com/${STACK_REPO}.git"
  fi
  git clone --branch "$STACK_BRANCH" --recurse-submodules "$auth_url" "$STACK_DIR"
else
  echo "[onstart] stack repo already cloned at $STACK_DIR -- pulling latest"
  git -C "$STACK_DIR" pull --rebase --recurse-submodules
fi

# 2. Belt-and-braces submodule init (idempotent)
git -C "$STACK_DIR" submodule update --init --recursive

# 3. Locate the provisioner-config.sh in the stack repo
PROVISIONER_CONFIG="$STACK_DIR/provisioner-config.sh"
if [ ! -f "$PROVISIONER_CONFIG" ]; then
  echo "[onstart] FATAL: $PROVISIONER_CONFIG not found in stack repo" >&2
  exit 1
fi
export PROVISIONER_CONFIG

# 4. Locate the provisioner script (in the submodule)
PROVISIONER_SCRIPT="$STACK_DIR/comfyui-provisioner/scripts/provision-comfyui.sh"
if [ ! -f "$PROVISIONER_SCRIPT" ]; then
  echo "[onstart] FATAL: $PROVISIONER_SCRIPT not found -- is the submodule initialized?" >&2
  exit 1
fi

# 5. Run the provisioner. WORKFLOWS_SRC_DIR points the framework at the stack's comfyui/ dir.
export WORKFLOWS_SRC_DIR="$STACK_DIR/comfyui"
bash "$PROVISIONER_SCRIPT"

echo "[onstart] provisioning complete -- ComfyUI should be reachable on the instance's port 18188"
