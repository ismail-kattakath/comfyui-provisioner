#!/usr/bin/env bash
# providers/vastai/onstart.sh
#
# VastAI provisioning script — invoked by the vastai/comfy image's declarative
# provisioner as Phase 9 ("Provisioning script"), AFTER workspace sync and
# supervisord launch but BEFORE the /.provisioning flag is cleared. This is
# the right point in the boot pipeline: ComfyUI's main.py won't start until
# we exit, so models/nodes/workflows are in place before service startup.
#
# Self-contained: clones the provisioner framework AND the stack repo
# INDEPENDENTLY — no recursive submodule descent. The submodule layout that
# may ship inside a stack repo is purely a local-dev convenience and
# intentionally not used at runtime (nested submodule clones can't reuse
# the top-level GH_TOKEN).
#
# Wiring on a VastAI instance (vastai create instance ...):
#   --onstart-cmd '/opt/instance-tools/bin/entrypoint.sh'      <-- image normal boot
#   --link-volume <VOLUME_ID>  --mount-path /workspace/ComfyUI/models   <-- OPTIONAL
#   --env "-e PROVISIONING_SCRIPT=<url-to-this-file> \
#          -e HF_TOKEN=hf_xxx \
#          -e STACK_REPO=owner/your-stack \
#          -e VOLUME_ID=<id-of-your-volume> \                  <-- OPTIONAL (paired with above)
#          -e PORTAL_CONFIG=... \
#          -e COMFYUI_ARGS=... \
#          ..."
#
# Volume is OPTIONAL. Setting VOLUME_ID + the --link-volume/--mount-path
# pair enables persistent storage for models + workflows + settings across
# instance destroys (the "single work-session, multi-stack" pattern).
# Omitting VOLUME_ID falls back to instance-disk-only — every destroy
# wipes models and you re-download next time.
#
# WHY OPTIONAL: VastAI's marketplace binds local volumes to a specific
# machine_id. Finding a machine with both a rentable GPU offer AND a
# co-located volume offer is often hard (only ~1 out of every 12+ active
# RTX 4090 hosts has both). The framework's soft-fallback lets you use
# any rentable GPU when co-location isn't available.
#
# See providers/vastai/template.json for the full env-var set and
# providers/vastai/README.md for the full create command + rationale.
#
# DO NOT use --onstart-cmd with curl|bash directly — that overwrites
# /root/onstart.sh and skips the image's vast_boot.d pipeline. The Open
# button 404s, Caddy never binds, ComfyUI never starts. Invoking
# entrypoint.sh as the onstart command lets the image set up everything
# (workspace sync, supervisord with full env, services) and runs this
# script via its PROVISIONING_SCRIPT hook at the correct phase.
#
# Required env (from --env at instance create):
#   HF_TOKEN          HuggingFace token (gated models + workflow fallbacks)
#   STACK_REPO        owner/repo containing provisioner-config.sh + comfyui/
#
# Required if STACK_REPO is private:
#   GH_TOKEN          GitHub PAT with read access to STACK_REPO
#
# Optional but recommended:
#   VOLUME_ID         VastAI volume id (enables persistent storage for models
#                     + workflows + settings). Paired with `--link-volume
#                     $VOLUME_ID --mount-path /workspace/ComfyUI/models` on
#                     the create-instance command. See header for marketplace
#                     co-location reality.
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

# VOLUME_ID is OPTIONAL. The VastAI marketplace co-location reality:
# volumes are bound to a specific machine_id, and finding a machine
# with BOTH a rentable GPU AND a co-located volume offer is often
# difficult (search both `vastai search offers` and `vastai search
# volumes`, find a machine_id intersection before booking). When
# co-location works, set VOLUME_ID + pass `--link-volume $VOLUME_ID
# --mount-path /workspace/ComfyUI/models` and your models + user state
# persist across destroys. When it doesn't, omit VOLUME_ID and accept
# that you'll re-download models on next instance.
#
# Soft-fallback semantics:
#   VOLUME_ID unset       -> no persistence; PERSIST_USER_STATE forced to 0
#   VOLUME_ID set + mount -> persistence enabled; PERSIST_USER_STATE defaults to 1
#   VOLUME_ID set, NO mnt -> FATAL (intent vs reality mismatch)
if [ -n "${VOLUME_ID:-}" ]; then
  if ! mountpoint -q /workspace/ComfyUI/models 2>/dev/null; then
    echo "[onstart] FATAL: VOLUME_ID=$VOLUME_ID is set but /workspace/ComfyUI/models is NOT a mountpoint." >&2
    echo "[onstart]        Did you forget --link-volume \$VOLUME_ID --mount-path /workspace/ComfyUI/models" >&2
    echo "[onstart]        on 'vastai create instance'? Unset VOLUME_ID to proceed without persistence." >&2
    exit 1
  fi
  echo "[onstart] volume check OK: VOLUME_ID=$VOLUME_ID mounted at /workspace/ComfyUI/models"
  export PERSIST_USER_STATE="${PERSIST_USER_STATE:-1}"
  export PERSIST_OUTPUTS="${PERSIST_OUTPUTS:-0}"
else
  echo "[onstart] VOLUME_ID unset — running without persistent storage."
  echo "[onstart]   Models will live on instance disk and be wiped on destroy."
  echo "[onstart]   Workflow edits + outputs likewise ephemeral."
  echo "[onstart]   To enable persistence: (a) find a machine_id with both a"
  echo "[onstart]   rentable GPU offer AND a co-located volume offer via:"
  echo "[onstart]     vastai search offers ... && vastai search volumes ..."
  echo "[onstart]   (b) create the volume; (c) re-launch with --link-volume +"
  echo "[onstart]   --mount-path /workspace/ComfyUI/models + -e VOLUME_ID=<id>"
  export PERSIST_USER_STATE=0
  export PERSIST_OUTPUTS=0
fi
echo "[onstart] PERSIST_USER_STATE=$PERSIST_USER_STATE  PERSIST_OUTPUTS=$PERSIST_OUTPUTS"

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

# 4b. Mirror HF_TOKEN to non-standard env-var aliases that some ComfyUI
#     custom_nodes read directly (instead of using huggingface_hub's
#     standard HF_TOKEN). Patches the comfyui program's supervisord
#     config so ComfyUI inherits the aliases when supervisord forks it.
#
#     Known consumers + their idiosyncratic env-var names:
#       HUGGINGFACE_TOKEN   — huchukato/ComfyUI-HuggingFace (source code)
#       HUGGINGFACE_API_KEY — huchukato/ComfyUI-HuggingFace (README claims)
#     The source and the README disagree on which name to use; setting
#     both is cheap and covers either reading path.
#
#     Why not just /etc/environment: supervisord caches its env at start
#     time and forks children with that cached env. Writing to
#     /etc/environment after supervisord booted is a no-op for ComfyUI.
#     Editing the per-program 'environment=' line + supervisorctl
#     reread/update/restart is the reliable path.
COMFYUI_SUPERVISORD_CONF="/etc/supervisor/conf.d/comfyui.conf"
if [ -f "$COMFYUI_SUPERVISORD_CONF" ]; then
  # %q-style quoting via sed so embedded shell-special chars round-trip safely.
  HF_TOKEN_ESC="$(printf '%s' "$HF_TOKEN" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  PATCHED=0
  if ! grep -q 'HUGGINGFACE_TOKEN=' "$COMFYUI_SUPERVISORD_CONF"; then
    sed -i "s|^environment=PROC_NAME=\"%(program_name)s\"|environment=PROC_NAME=\"%(program_name)s\",HUGGINGFACE_TOKEN=\"$HF_TOKEN_ESC\"|" "$COMFYUI_SUPERVISORD_CONF"
    PATCHED=1
  fi
  if ! grep -q 'HUGGINGFACE_API_KEY=' "$COMFYUI_SUPERVISORD_CONF"; then
    # Append after HUGGINGFACE_TOKEN= (which we just ensured exists)
    sed -i "s|HUGGINGFACE_TOKEN=\"$HF_TOKEN_ESC\"|HUGGINGFACE_TOKEN=\"$HF_TOKEN_ESC\",HUGGINGFACE_API_KEY=\"$HF_TOKEN_ESC\"|" "$COMFYUI_SUPERVISORD_CONF"
    PATCHED=1
  fi
  if [ "$PATCHED" = "1" ]; then
    echo "[onstart] patched $COMFYUI_SUPERVISORD_CONF with HF token aliases (HUGGINGFACE_TOKEN + HUGGINGFACE_API_KEY)"
    supervisorctl reread 2>&1 | sed 's/^/[onstart] /'
    supervisorctl update comfyui 2>&1 | sed 's/^/[onstart] /'
    # NOTE: comfyui will restart on its own via 'update'. We don't
    # explicitly restart here — the boot pipeline's services-restart block
    # later handles it as part of the standard onstart epilogue.
  fi
fi

# 5. Persist tokens + config to /workspace/.provisioner.env so the operator
#    can re-run the provisioner from an interactive SSH session. VastAI
#    doesn't export the boot env to SSH shells, so without this file a
#    manual `bash scripts/provision-comfyui.sh` aborts with
#    "HF_TOKEN must be set in the environment". Values are written with
#    `printf %q` so they round-trip safely when sourced.
#
#    Permissions: file is created under `umask 077` and explicitly
#    chmod 600. The values themselves are NEVER echoed to stdout (the
#    masking pattern in provision-comfyui.sh handles human-visible
#    token display elsewhere).
(
  umask 077
  {
    printf "# Auto-generated by providers/vastai/onstart.sh -- do not edit.\n"
    printf "# Source this file in an SSH session before re-running the\n"
    printf "# provisioner manually:\n"
    printf "#   source /workspace/.provisioner.env\n"
    printf "#   bash %s/scripts/provision-comfyui.sh\n" "$PROVISIONER_DIR"
    printf "# Or use the wrapper: bash /workspace/reprovision.sh\n"
    printf "export HF_TOKEN=%q\n"             "${HF_TOKEN}"
    # Aliases for huchukato/ComfyUI-HuggingFace which reads non-standard
    # HUGGINGFACE_TOKEN in its source (server/utils.py) and
    # HUGGINGFACE_API_KEY in its README — set both so either reading
    # path works. All point at the same value as HF_TOKEN.
    printf "export HUGGINGFACE_TOKEN=%q\n"    "${HF_TOKEN}"
    printf "export HUGGINGFACE_API_KEY=%q\n"  "${HF_TOKEN}"
    printf "export CIVITAI_API_KEY=%q\n"      "${CIVITAI_API_KEY:-}"
    printf "export GH_TOKEN=%q\n"           "${GH_TOKEN:-}"
    printf "export STACK_REPO=%q\n"         "${STACK_REPO}"
    printf "export STACK_BRANCH=%q\n"       "${STACK_BRANCH}"
    printf "export STACK_DIR=%q\n"          "${STACK_DIR}"
    printf "export PROVISIONER_REPO=%q\n"   "${PROVISIONER_REPO}"
    printf "export PROVISIONER_BRANCH=%q\n" "${PROVISIONER_BRANCH}"
    printf "export PROVISIONER_DIR=%q\n"    "${PROVISIONER_DIR}"
    printf "export PROVISIONER_CONFIG=%q\n" "${PROVISIONER_CONFIG}"
    printf "export WORKFLOWS_SRC_DIR=%q\n"  "${WORKFLOWS_SRC_DIR}"
    printf "export VOLUME_ID=%q\n"          "${VOLUME_ID:-}"
    printf "export PERSIST_USER_STATE=%q\n" "${PERSIST_USER_STATE}"
    printf "export PERSIST_OUTPUTS=%q\n"    "${PERSIST_OUTPUTS}"
  } > /workspace/.provisioner.env
)
chmod 600 /workspace/.provisioner.env
echo "[onstart] wrote /workspace/.provisioner.env (chmod 600)"

# Source it from interactive SSH shells so re-running the provisioner is
# friction-free. Only append the line once (idempotent on re-boots).
if [ -f /root/.bashrc ] && ! grep -qF "/workspace/.provisioner.env" /root/.bashrc; then
  printf "\n# Auto-load provisioner env (written by comfyui-provisioner onstart.sh)\n[ -f /workspace/.provisioner.env ] && source /workspace/.provisioner.env\n" >> /root/.bashrc
  echo "[onstart] appended provisioner-env loader to /root/.bashrc"
fi

# Drop a one-shot wrapper so re-provisioning is a single command. Useful
# when iterating on a stack repo's provisioner-config.sh or workflows.
cat > /workspace/reprovision.sh <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Re-run the comfyui-provisioner against the current stack.
# Sources /workspace/.provisioner.env (written by onstart.sh at boot) so
# the SSH session has the same env the original boot had.
set -euo pipefail
if [ ! -f /workspace/.provisioner.env ]; then
  echo "ERROR: /workspace/.provisioner.env not found." >&2
  echo "       Either onstart.sh hasn't completed yet, or this isn't a" >&2
  echo "       vastai/comfy instance bootstrapped by comfyui-provisioner." >&2
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
echo "[onstart] wrote /workspace/reprovision.sh (re-run with: bash /workspace/reprovision.sh)"

bash "$PROVISIONER_DIR/scripts/provision-comfyui.sh"

# --- Portal regeneration (per Vast docs PROVISIONING_SCRIPT example) -----
# https://docs.vast.ai/guides/templates/advanced-setup
#
# The vastai CLI's --env string is parsed as docker run flags, which means
# PORTAL_CONFIG values containing spaces (e.g. "Instance Portal") get
# word-split before reaching the container — silently truncating to the
# first word. Comfyui's supervisor script then greps for "ComfyUI" in
# /etc/portal.yaml, doesn't find it (because portal.yaml regenerated from
# the truncated config), and prints "Skipping comfyui startup (not in
# /etc/portal.yaml)". The Open button loads forever.
#
# Per the docs' own PROVISIONING_SCRIPT example, the script is expected
# to `export PORTAL_CONFIG=...` itself and `rm /etc/portal.yaml` so the
# Portal regenerates cleanly. We do that here with a default suited to
# the vastai/comfy image. Users who want a custom layout can override
# via the PROVISIONER_PORTAL_CONFIG env var (which avoids the --env
# word-split because we set PORTAL_CONFIG inside this script, not via
# the CLI).
DEFAULT_PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:8188:18188:/:ComfyUI|localhost:8288:18288:/docs:API Wrapper|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing"
export PORTAL_CONFIG="${PROVISIONER_PORTAL_CONFIG:-$DEFAULT_PORTAL_CONFIG}"
echo "[onstart] PORTAL_CONFIG set (${#PORTAL_CONFIG} chars, $(echo "$PORTAL_CONFIG" | tr -cd '|' | wc -c) app separators)"

# Persist to /etc/environment so subprocesses (Caddy, instance_portal,
# comfyui supervisor) all see the same value after supervisorctl restart.
# Use python3 (always present on vastai/comfy) for portable file editing.
python3 -c '
import os, re, sys
path = "/etc/environment"
key = "PORTAL_CONFIG"
val = os.environ["PORTAL_CONFIG"]
try:
    txt = open(path).read()
except FileNotFoundError:
    txt = ""
new_line = f"{key}=\"{val}\"\n"
if re.search(rf"^{key}=", txt, flags=re.M):
    txt = re.sub(rf"^{key}=.*$", new_line.rstrip(), txt, flags=re.M)
else:
    txt = txt.rstrip() + ("\n" if txt else "") + new_line
open(path, "w").write(txt)
print(f"[onstart] /etc/environment now has correct PORTAL_CONFIG ({len(val)} chars)")
'

# Now remove stale /etc/portal.yaml + /etc/Caddyfile and restart the
# services that read PORTAL_CONFIG. instance_portal regenerates
# /etc/portal.yaml; caddy_config_manager regenerates /etc/Caddyfile;
# the comfyui supervisor script will now find "ComfyUI" in portal.yaml;
# tunnel_manager serves /get-direct-url which the Portal's "Launch
# Application" buttons hit to resolve external URLs (without it, the
# Portal renders but every Launch button toasts "No URL is available").
echo "[onstart] removing /etc/portal.yaml + /etc/Caddyfile so they regenerate"
rm -f /etc/portal.yaml /etc/Caddyfile
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl restart instance_portal tunnel_manager caddy comfyui 2>&1 | sed 's/^/[onstart] /'
fi

# DO NOT start supervisord here. The image's /etc/vast_boot.d pipeline
# launched it before this script ran (65-supervisor-launch.sh) and will
# remove the /.provisioning flag after (95-supervisor-wait.sh), at
# which point supervisord starts the comfyui service automatically.

echo "[onstart] provisioning complete -- ComfyUI should be reachable on port 18188 shortly"
