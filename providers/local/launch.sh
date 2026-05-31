#!/usr/bin/env bash
# providers/local/launch.sh
#
# Local provisioning + launch for development on macOS / Linux.
#
# Installs ComfyUI on demand (via comfy-cli) when one isn't already present,
# then runs the generic provisioner against your stack config. This makes the
# `local` provider self-contained: the devcontainer no longer installs ComfyUI
# in its lifecycle — installation is a local-provider concern handled here, so
# devcontainer and non-devcontainer users get the same end-state.
#
# Usage:
#   PROVISIONER_CONFIG=/path/to/your/stack/provisioner-config.sh \
#   WORKFLOWS_SRC_DIR=/path/to/your/stack/comfyui \
#   bash providers/local/launch.sh
#
# Key env vars:
#   COMFYUI_DIR              Explicit ComfyUI root (the dir containing main.py).
#                            If set and valid, it is used as-is and nothing is installed.
#                            If set but missing, the script errors — your intent is
#                            authoritative; it will not silently install elsewhere.
#   COMFY_WORKSPACE          Parent dir for auto-install (default: $HOME/comfy).
#                            comfy-cli installs ComfyUI at $COMFY_WORKSPACE/ComfyUI.
#   COMFY_INSTALL_ARGS       Extra args forwarded to `comfy install` (e.g. --cpu, --nvidia).
#                            Intentionally NOT defaulted — comfy-cli auto-detects the
#                            accelerator, and hardcoding --cpu would be wrong on a Mac (MPS)
#                            or a GPU box.
#   COMFY_NO_AUTO_INSTALL=1  Disable auto-install; error if no ComfyUI is found (the old
#                            guard behaviour, for users who manage their own install).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER_SCRIPT="$SCRIPT_DIR/../../scripts/provision-comfyui.sh"

: "${PROVISIONER_CONFIG:?PROVISIONER_CONFIG must point to the stack provisioner-config.sh}"

log() { printf '[local] %s\n' "$*"; }
err() { printf '[local] ERROR: %s\n' "$*" >&2; }

# A usable ComfyUI root is a directory that directly contains main.py — matching
# what scripts/provision-comfyui.sh treats as COMFYUI_DIR.
is_comfy_install() { [ -n "${1:-}" ] && [ -f "$1/main.py" ]; }

ensure_comfy_cli() {
  if command -v comfy >/dev/null 2>&1; then return 0; fi
  log "comfy-cli not found — installing it (pip install --user comfy-cli)"
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --user --upgrade comfy-cli
  elif command -v pip >/dev/null 2>&1; then
    pip install --user --upgrade comfy-cli
  else
    err "No pip found to install comfy-cli. Install Python+pip, or install comfy-cli manually."
    exit 1
  fi
  if ! command -v comfy >/dev/null 2>&1; then
    err "comfy-cli installed but 'comfy' is not on PATH."
    err "Add your Python user-base bin dir to PATH:  export PATH=\"\$(python3 -m site --user-base)/bin:\$PATH\""
    exit 1
  fi
}

# ---- Resolve or install ComfyUI -------------------------------------------

if [ -n "${COMFYUI_DIR:-}" ]; then
  # Explicit path: authoritative. Use if valid; error if not (no silent relocation).
  if is_comfy_install "$COMFYUI_DIR"; then
    log "Using existing ComfyUI at COMFYUI_DIR=$COMFYUI_DIR"
  else
    err "COMFYUI_DIR=$COMFYUI_DIR is set but contains no ComfyUI (no main.py)."
    err "Create a ComfyUI there, or unset COMFYUI_DIR to let this script auto-install one."
    exit 1
  fi
else
  # No explicit path: prefer a known existing install before installing fresh.
  for cand in "$HOME/comfy/ComfyUI" "$HOME/comfyui"; do
    if is_comfy_install "$cand"; then
      COMFYUI_DIR="$cand"
      log "Found existing ComfyUI at $COMFYUI_DIR"
      break
    fi
  done

  if [ -z "${COMFYUI_DIR:-}" ]; then
    if [ "${COMFY_NO_AUTO_INSTALL:-0}" = "1" ]; then
      err "No ComfyUI found and COMFY_NO_AUTO_INSTALL=1. Install ComfyUI or set COMFYUI_DIR."
      exit 1
    fi
    ensure_comfy_cli
    COMFY_WORKSPACE="${COMFY_WORKSPACE:-$HOME/comfy}"
    log "No ComfyUI found — installing via comfy-cli into workspace $COMFY_WORKSPACE"
    # COMFY_INSTALL_ARGS is intentionally unquoted so multiple args expand.
    # shellcheck disable=SC2086
    comfy --workspace "$COMFY_WORKSPACE" install ${COMFY_INSTALL_ARGS:-}

    # comfy-cli nests the install at <workspace>/ComfyUI; trust that, but fall back
    # to comfy-cli's own report if the layout ever differs.
    COMFYUI_DIR="$COMFY_WORKSPACE/ComfyUI"
    if ! is_comfy_install "$COMFYUI_DIR"; then
      resolved="$(comfy which 2>/dev/null | head -n1 || true)"
      resolved="${resolved#Target ComfyUI path: }"
      if is_comfy_install "$resolved"; then COMFYUI_DIR="$resolved"; fi
    fi
    if ! is_comfy_install "$COMFYUI_DIR"; then
      err "comfy install did not produce a usable ComfyUI at $COMFYUI_DIR"
      exit 1
    fi
    log "Installed ComfyUI at $COMFYUI_DIR"
  fi
fi

# ---- Provision -------------------------------------------------------------

# Skip phases that don't make sense locally
export SKIP_SYSTEM="${SKIP_SYSTEM:-1}"     # no apt-get on macOS
export SKIP_RESTART="${SKIP_RESTART:-1}"   # no supervisorctl locally
export COMFYUI_DIR

bash "$PROVISIONER_SCRIPT"

echo
echo "Done. To launch ComfyUI now:"
echo "  comfy --workspace \"$(dirname "$COMFYUI_DIR")\" launch -- --listen 127.0.0.1 --port 8188"
