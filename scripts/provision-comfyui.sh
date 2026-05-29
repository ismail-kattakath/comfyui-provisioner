#!/usr/bin/env bash
# provision-comfyui.sh
#
# Generic ComfyUI provisioner — runs seven idempotent phases against a stack
# defined externally via $PROVISIONER_CONFIG:
#   0. Preflight   — env-var checks, ComfyUI install detection, pip detection
#   1. System      — apt update/upgrade (Linux root) + comfyui-manager pip upgrade
#   2. Tokens      — write HF / Civitai / GH tokens into ComfyUI's manager config
#   3. Nodes       — clone / pin custom nodes from NODE_MAP (with ALIAS_MAP renames)
#   4. Workflows   — stage WORKFLOW_MAP entries from $WORKFLOWS_SRC_DIR (+ fallback URL)
#   5. Models      — download MODEL_MAP (HF + public URLs) + MODEL_MAP_CIVITAI (sha-verified)
#   6. Update      — pull latest ComfyUI core + Manager + every unpinned custom node
#   7. Restart     — supervisorctl restart comfyui  (no-op if HAS_SUPERVISOR=0)
#
# Idempotent: safe to re-run. Resumes interrupted downloads, short-circuits on
# completed files (size + sha256 match), reuses clones, never overwrites tokens.
#
# Supported environments:
#   - macOS dev          (~/comfyui)
#   - VastAI vastai/comfy  (/opt/workspace-internal/ComfyUI)
#   - RunPod / worker-comfyui  (/workspace/ComfyUI)
# Override via COMFYUI_DIR if your install lives elsewhere.

set -euo pipefail

trap 'rc=$?; echo "[ERR] line $LINENO exited $rc (last cmd: ${BASH_COMMAND})" >&2; exit $rc' ERR

# ---------- Logging helpers ----------
log()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR]  %s\n' "$*" >&2; }
banner() { printf '\n===== %s =====\n' "$*"; }

# ---------- Mask helper (defensive — never echo tokens) ----------
mask() {
  local v="${1-}"
  if [ -z "$v" ]; then printf '(unset)'; return; fi
  local n=${#v}
  if [ "$n" -le 8 ]; then printf '****'; else printf '%s...%s' "${v:0:4}" "${v: -4}"; fi
}

# ---------- Phase 0 — Preflight ----------
banner "Phase 0 — Preflight"

: "${HF_TOKEN:?HF_TOKEN must be set in the environment for HuggingFace downloads}"
log "HF_TOKEN: $(mask "$HF_TOKEN")"
[ -n "${GITHUB_TOKEN:-}" ]         && log "GITHUB_TOKEN: $(mask "$GITHUB_TOKEN")"         || log "GITHUB_TOKEN: (unset)"
[ -n "${CIVITAI_API_KEY:-}" ]  && log "CIVITAI_API_KEY: $(mask "$CIVITAI_API_KEY")" || log "CIVITAI_API_KEY: (unset)"

# ---------- Config (NODE_MAP, ALIAS_MAP, MODEL_MAP, MODEL_MAP_CIVITAI, WORKFLOW_MAP) ----------
# This provisioner is generic — the stack-specific lists live in an external
# config file. Set PROVISIONER_CONFIG to its path, e.g.:
#   PROVISIONER_CONFIG=/workspace/your-stack-repo/provisioner-config.sh
# If unset, looks for $SCRIPT_DIR/../../provisioner-config.sh (parent repo convention).
#
# Pre-declare all five arrays as empty so phases can safely use ${#ARRAY[@]}
# under `set -u` even when the config omits some of them. The sourced config
# overwrites these with its own contents.
declare -a NODE_MAP=()
declare -a ALIAS_MAP=()
declare -a MODEL_MAP=()
declare -a MODEL_MAP_CIVITAI=()
declare -a WORKFLOW_MAP=()

SCRIPT_DIR_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER_CONFIG="${PROVISIONER_CONFIG:-$SCRIPT_DIR_EARLY/../../provisioner-config.sh}"
if [ -f "$PROVISIONER_CONFIG" ]; then
  log "PROVISIONER_CONFIG: $PROVISIONER_CONFIG"
  # shellcheck disable=SC1090
  source "$PROVISIONER_CONFIG"
else
  warn "PROVISIONER_CONFIG not found at $PROVISIONER_CONFIG — NODE_MAP/MODEL_MAP* must be set in the environment or Phases 3, 4, 5 will be no-ops."
fi

# Detect COMFYUI_DIR — check runtime locations first, fall back to image
# source locations only if no runtime copy exists.
#
# IMPORTANT: order matters. On vastai/comfy, BOTH paths exist after the
# image's 36-sync-workspace.sh runs:
#   /workspace/ComfyUI            — the RUNTIME location (supervisor's
#                                    comfyui.sh launches python main.py here)
#   /opt/workspace-internal/ComfyUI — the SOURCE that 36-sync-workspace.sh
#                                    copies FROM into /workspace
# Provisioning into /opt/... would be silently dropped — ComfyUI doesn't
# read from there. Always prefer /workspace/ComfyUI when both exist.
COMFYUI_CANDIDATES=(
  "/workspace/ComfyUI"
  "/comfyui"
  "$HOME/comfyui"
  "/opt/workspace-internal/ComfyUI"
)
if [ -z "${COMFYUI_DIR:-}" ]; then
  for cand in "${COMFYUI_CANDIDATES[@]}"; do
    if [ -d "$cand" ]; then COMFYUI_DIR="$cand"; break; fi
  done
fi
if [ -z "${COMFYUI_DIR:-}" ] || [ ! -d "$COMFYUI_DIR" ]; then
  err "Could not find a ComfyUI install. Tried: ${COMFYUI_CANDIDATES[*]}. Set COMFYUI_DIR to override."
  exit 1
fi
log "COMFYUI_DIR=$COMFYUI_DIR"

# Detect COMFY_PIP
if [ -z "${COMFY_PIP:-}" ]; then
  for cand in "/venv/main/bin/pip" "$COMFYUI_DIR/.venv/bin/pip" "$(command -v pip3 || true)" "$(command -v pip || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then COMFY_PIP="$cand"; break; fi
  done
fi
if [ -z "${COMFY_PIP:-}" ] || [ ! -x "$COMFY_PIP" ]; then
  err "Could not locate a pip binary. Set COMFY_PIP to override."
  exit 1
fi
log "COMFY_PIP=$COMFY_PIP"

# Platform
PLATFORM="$(uname -s)"
log "PLATFORM=$PLATFORM"

# Supervisor
HAS_SUPERVISOR=0
if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status comfyui >/dev/null 2>&1; then
  HAS_SUPERVISOR=1
fi
log "HAS_SUPERVISOR=$HAS_SUPERVISOR"

# COMFY_PORT
if [ -z "${COMFY_PORT:-}" ]; then
  if [ -f /etc/environment ] && grep -q -- "--port 18188" /etc/environment 2>/dev/null; then
    COMFY_PORT=18188
  else
    COMFY_PORT=8188
  fi
fi
log "COMFY_PORT=$COMFY_PORT"

# Paths
CUSTOM_NODES="$COMFYUI_DIR/custom_nodes"
MODELS="$COMFYUI_DIR/models"
WORKFLOWS="$COMFYUI_DIR/user/default/workflows"
MANAGER_CFG="$COMFYUI_DIR/user/__manager/config.ini"

mkdir -p \
  "$CUSTOM_NODES" \
  "$MODELS"/checkpoints \
  "$MODELS"/diffusion_models \
  "$MODELS"/text_encoders \
  "$MODELS"/latent_upscale_models \
  "$MODELS"/vae \
  "$MODELS"/loras \
  "$WORKFLOWS" \
  "$(dirname "$MANAGER_CFG")"
# Note: model subdirectories beyond the common set above are created on
# demand by download_model (mkdir -p "$(dirname "$dest")") when MODEL_MAP
# entries reference them — e.g. "loras/my-subdir/foo.safetensors" works
# even though loras/my-subdir/ isn't pre-created here.

# ---------- User-state persistence on volume (opt-in, two flags) ----------
# Two independent flags:
#   PERSIST_USER_STATE=1  — symlinks workflows + comfy.settings.json to the
#                            volume so your Cmd+S edits and UI prefs survive
#                            instance destroy. Default 0 (opt-in by provider).
#   PERSIST_OUTPUTS=1     — ALSO symlinks ComfyUI/output and ComfyUI/input
#                            to the volume. Default 0. Off by default because
#                            for the "iterate on workflow → ship as API"
#                            pattern, outputs are ephemeral test artifacts
#                            best left on instance disk (auto-wiped on
#                            destroy). Set to 1 only if you need
#                            generated images/videos to survive destroy
#                            without downloading them off the instance.
#
# Layout under $MODELS/_user/:
#   workflows/                       <- user/default/workflows symlink target
#   comfy.settings.json              <- user/default/comfy.settings.json symlink target
#   output/                          <- ComfyUI/output symlink target  (only if PERSIST_OUTPUTS=1)
#   input/                           <- ComfyUI/input symlink target   (only if PERSIST_OUTPUTS=1)
#
# Idempotent: if the symlink already points to the right target, no-op.
# Safe: rescues any pre-existing content under the canonical paths by
# moving it into the volume before replacing with a symlink.
if [ "${PERSIST_USER_STATE:-0}" = "1" ]; then
  banner "User-state persistence — symlinking into volume at $MODELS/_user/ (PERSIST_OUTPUTS=${PERSIST_OUTPUTS:-0})"
  USER_STATE_ROOT="$MODELS/_user"
  mkdir -p "$USER_STATE_ROOT/workflows"

  # path-on-disk -> path-on-volume pairs. Workflows + settings always
  # persisted; output + input gated on PERSIST_OUTPUTS=1.
  declare -a PERSIST_PAIRS=(
    "$COMFYUI_DIR/user/default/workflows|$USER_STATE_ROOT/workflows"
    "$COMFYUI_DIR/user/default/comfy.settings.json|$USER_STATE_ROOT/comfy.settings.json"
  )
  if [ "${PERSIST_OUTPUTS:-0}" = "1" ]; then
    mkdir -p "$USER_STATE_ROOT"/{output,input}
    PERSIST_PAIRS+=(
      "$COMFYUI_DIR/output|$USER_STATE_ROOT/output"
      "$COMFYUI_DIR/input|$USER_STATE_ROOT/input"
    )
  fi
  for pair in "${PERSIST_PAIRS[@]}"; do
    IFS="|" read -r src dst <<<"$pair"
    mkdir -p "$(dirname "$src")"
    if [ -L "$src" ]; then
      # Already a symlink — verify it points to our target, fix if not
      cur="$(readlink "$src")"
      if [ "$cur" = "$dst" ]; then
        log "[symlink] $src already points to $dst"
        continue
      fi
      log "[symlink] $src points to $cur (wrong) — repointing to $dst"
      rm -f "$src"
    elif [ -e "$src" ]; then
      # Real file/dir exists — rescue contents into the volume first
      if [ -d "$src" ] && [ -d "$dst" ]; then
        # Move any not-yet-on-volume files from src into dst (preserve newer)
        log "[rescue] copying $src/* into $dst/ (preserving newer on volume)"
        if command -v rsync >/dev/null 2>&1; then
          rsync -a --ignore-existing "$src/" "$dst/" || warn "rsync failed for $src"
        else
          cp -rn "$src"/. "$dst/" 2>/dev/null || true
        fi
        rm -rf "$src"
      elif [ -f "$src" ] && [ ! -f "$dst" ]; then
        log "[rescue] moving $src to $dst"
        mv "$src" "$dst"
      else
        log "[skip] $src already has content but $dst also exists — keeping volume copy"
        rm -rf "$src"
      fi
    fi
    ln -s "$dst" "$src"
    log "[symlink] $src -> $dst"
  done
fi

# Portable filesize helper
filesize() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return; }
  if [ "$PLATFORM" = "Darwin" ]; then
    stat -f%z "$f" 2>/dev/null || printf '0'
  else
    stat -c%s "$f" 2>/dev/null || printf '0'
  fi
}

# Inject x-access-token for github clones when GITHUB_TOKEN set
git_auth_url() {
  local url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ] && [[ "$url" == https://github.com/* ]]; then
    printf 'https://x-access-token:%s@github.com/%s' "$GITHUB_TOKEN" "${url#https://github.com/}"
  else
    printf '%s' "$url"
  fi
}

# upsert KEY=VALUE in a file (replaces line if exists, else appends)
upsert_kv() {
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} {
      if ($1 == k) { print k "=" v } else { print $0 }
    }' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# ---------- Phase 1 — System update + Manager pip upgrade ----------
if [ "${SKIP_SYSTEM:-0}" != "1" ]; then
  banner "Phase 1 — System update + Manager pip upgrade"
  if [ "$PLATFORM" = "Linux" ] && [ "$EUID" -eq 0 ]; then
    log "Running apt-get update + upgrade (root on Linux)"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get -qq -y upgrade
  else
    log "[skip] apt update/upgrade (not Linux root)"
  fi
  log "Upgrading comfyui-manager via pip"
  "$COMFY_PIP" install -q -U --pre comfyui-manager
  "$COMFY_PIP" show comfyui-manager | awk '/^(Name|Version):/{print}'
else
  banner "Phase 1 — System update + Manager pip upgrade [SKIPPED]"
fi

# ---------- Phase 2 — Config + tokens ----------
banner "Phase 2 — Config + tokens"

# security_level = weak in MANAGER_CFG
if [ ! -f "$MANAGER_CFG" ]; then
  log "Creating $MANAGER_CFG with [default] section"
  mkdir -p "$(dirname "$MANAGER_CFG")"
  {
    printf '[default]\n'
    printf 'security_level = weak\n'
  } > "$MANAGER_CFG"
else
  if grep -qE '^[[:space:]]*security_level[[:space:]]*=' "$MANAGER_CFG"; then
    log "Updating security_level in $MANAGER_CFG"
    tmp="$(mktemp)"
    awk '{
      if ($0 ~ /^[[:space:]]*security_level[[:space:]]*=/) print "security_level = weak"
      else print $0
    }' "$MANAGER_CFG" > "$tmp"
    mv "$tmp" "$MANAGER_CFG"
  else
    log "Appending security_level = weak to $MANAGER_CFG"
    if ! grep -q '^\[default\]' "$MANAGER_CFG"; then
      tmp="$(mktemp)"
      { printf '[default]\n'; cat "$MANAGER_CFG"; } > "$tmp"
      mv "$tmp" "$MANAGER_CFG"
    fi
    printf 'security_level = weak\n' >> "$MANAGER_CFG"
  fi
fi

# --enable-manager in COMFYUI_ARGS
DEFAULT_COMFY_ARGS="--listen 0.0.0.0 --port $COMFY_PORT --enable-cors-header --enable-manager"
if [ "$PLATFORM" = "Linux" ] && [ -f /etc/environment ] && [ -w /etc/environment ]; then
  ARGS_FILE="/etc/environment"
  if grep -qE '^COMFYUI_ARGS=' "$ARGS_FILE"; then
    if ! grep -E '^COMFYUI_ARGS=' "$ARGS_FILE" | grep -q -- "--enable-manager"; then
      log "Appending --enable-manager to existing COMFYUI_ARGS in /etc/environment"
      tmp="$(mktemp)"
      awk '{
        if ($0 ~ /^COMFYUI_ARGS=/) {
          line = $0
          n = length(line)
          last = substr(line, n, 1)
          if (last == "\"" || last == "'\''") {
            print substr(line, 1, n-1) " --enable-manager" last
          } else {
            print line " --enable-manager"
          }
        } else {
          print $0
        }
      }' "$ARGS_FILE" > "$tmp"
      mv "$tmp" "$ARGS_FILE"
    else
      log "[ok] COMFYUI_ARGS already contains --enable-manager"
    fi
  else
    log "Writing default COMFYUI_ARGS to /etc/environment"
    printf 'COMFYUI_ARGS="%s"\n' "$DEFAULT_COMFY_ARGS" >> "$ARGS_FILE"
  fi
else
  ARGS_FILE="$HOME/.comfyui-args"
  if [ -f "$ARGS_FILE" ] && grep -qE '^COMFYUI_ARGS=' "$ARGS_FILE"; then
    if ! grep -E '^COMFYUI_ARGS=' "$ARGS_FILE" | grep -q -- "--enable-manager"; then
      log "Appending --enable-manager to existing COMFYUI_ARGS in $ARGS_FILE"
      tmp="$(mktemp)"
      awk '{
        if ($0 ~ /^COMFYUI_ARGS=/) {
          line = $0
          n = length(line)
          last = substr(line, n, 1)
          if (last == "\"" || last == "'\''") {
            print substr(line, 1, n-1) " --enable-manager" last
          } else {
            print line " --enable-manager"
          }
        } else {
          print $0
        }
      }' "$ARGS_FILE" > "$tmp"
      mv "$tmp" "$ARGS_FILE"
    else
      log "[ok] COMFYUI_ARGS already contains --enable-manager"
    fi
  else
    log "Writing default COMFYUI_ARGS to $ARGS_FILE"
    printf 'COMFYUI_ARGS="%s"\n' "$DEFAULT_COMFY_ARGS" >> "$ARGS_FILE"
  fi
fi

# Persist tokens
if [ "$PLATFORM" = "Linux" ] && [ -f /etc/environment ] && [ -w /etc/environment ]; then
  TOKEN_FILE="/etc/environment"
else
  TOKEN_FILE="$HOME/.comfyui-tokens.env"
  [ -f "$TOKEN_FILE" ] || { : > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; }
fi
log "Persisting tokens to $TOKEN_FILE"
[ -n "${HF_TOKEN:-}" ]        && upsert_kv "$TOKEN_FILE" "HF_TOKEN"        "$HF_TOKEN"
[ -n "${GITHUB_TOKEN:-}" ]        && upsert_kv "$TOKEN_FILE" "GITHUB_TOKEN"        "$GITHUB_TOKEN"
[ -n "${CIVITAI_API_KEY:-}" ] && upsert_kv "$TOKEN_FILE" "CIVITAI_API_KEY" "$CIVITAI_API_KEY"
if [ "$TOKEN_FILE" = "$HOME/.comfyui-tokens.env" ]; then
  chmod 600 "$TOKEN_FILE"
fi

# ---------- Phase 3 — Custom nodes ----------
if [ "${SKIP_NODES:-0}" != "1" ]; then
  banner "Phase 3 — Custom nodes"

  # 3a — rename legacy folders
  log "-- 3a: rename legacy folders"
  for pair in "${ALIAS_MAP[@]}"; do
    legacy="${pair%%:*}"
    canon="${pair#*:}"
    legacy_path="$CUSTOM_NODES/$legacy"
    canon_path="$CUSTOM_NODES/$canon"
    if [ -d "$legacy_path" ]; then
      if [ ! -d "$canon_path" ]; then
        log "[rename] $legacy -> $canon"
        mv "$legacy_path" "$canon_path"
      else
        ts="$(date +%Y%m%d%H%M%S)"
        log "[rename] both '$legacy' and '$canon' exist — archiving legacy as ${legacy}.duplicate.${ts}"
        mv "$legacy_path" "$CUSTOM_NODES/${legacy}.duplicate.${ts}"
      fi
    fi
  done

  # 3b — install / fix each node
  log "-- 3b: install / fix nodes"
  for entry in "${NODE_MAP[@]}"; do
    IFS='|' read -r repo pin folder extra <<<"$entry"
    target="$CUSTOM_NODES/$folder"
    name="$folder"

    if [ -d "$target/.git" ]; then
      if [ -n "$pin" ]; then
        head_sha="$(git -C "$target" rev-parse HEAD 2>/dev/null || echo unknown)"
        if [ "$head_sha" = "$pin" ]; then
          log "[ok] $name @ ${pin:0:8}"
        else
          log "[pin-fix] $name: $head_sha -> $pin"
          if git -C "$target" fetch --quiet origin "$pin" --depth=1 2>/dev/null; then
            git -C "$target" checkout --quiet "$pin" || warn "checkout failed for $name"
          else
            warn "could not fetch pin $pin for $name (HEAD left at $head_sha)"
          fi
        fi
      else
        log "[ok] $name (unpinned)"
      fi
    else
      auth_repo="$(git_auth_url "$repo")"
      log "[clone] $name <- $repo"
      git clone --quiet "$auth_repo" "$target"
      if [ -n "$pin" ]; then
        log "[pin-fix] $name -> ${pin:0:8}"
        if ! git -C "$target" checkout --quiet "$pin" 2>/dev/null; then
          if git -C "$target" fetch --quiet origin "$pin" --depth=1 2>/dev/null; then
            git -C "$target" checkout --quiet "$pin" || warn "checkout failed for $name"
          else
            warn "could not fetch pin $pin for $name"
          fi
        fi
      fi
    fi

    if [ -f "$target/requirements.txt" ]; then
      "$COMFY_PIP" install -q -r "$target/requirements.txt" || warn "pip install requirements.txt failed for $name"
    fi
    if [ -n "$extra" ]; then
      # shellcheck disable=SC2086
      "$COMFY_PIP" install -q $extra || warn "pip install '$extra' failed for $name"
    fi
  done

else
  banner "Phase 3 — Custom nodes [SKIPPED]"
fi

# ---------- Phase 4 — Workflow JSON ----------
if [ "${SKIP_WORKFLOW:-0}" != "1" ]; then
  banner "Phase 4 — Workflow JSON"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  WORKFLOWS_SRC_DIR="${WORKFLOWS_SRC_DIR:-$SCRIPT_DIR/../../comfyui}"

  if [ "${#WORKFLOW_MAP[@]}" -eq 0 ]; then
    warn "WORKFLOW_MAP is empty — define it in your PROVISIONER_CONFIG to stage workflows. Skipping Phase 4."
  else
    for entry in "${WORKFLOW_MAP[@]}"; do
      [ -z "$entry" ] && continue
      IFS="|" read -r fname fallback_url <<<"$entry"
      target="$WORKFLOWS/$fname"
      src="$WORKFLOWS_SRC_DIR/$fname"
      # Preserve user edits across re-provisions: skip if the target already
      # exists, unless FORCE_RESTAGE=1 is set explicitly. This matters when
      # $WORKFLOWS is symlinked to a persistent volume (PERSIST_USER_STATE=1)
      # — without this guard, every re-provision would clobber the user's
      # saved edits with the pristine workflow from the stack repo.
      if [ -f "$target" ] && [ "${FORCE_RESTAGE:-0}" != "1" ]; then
        log "[skip] $fname already present at $target — preserving user edits (FORCE_RESTAGE=1 to override)"
        continue
      fi
      if [ -f "$src" ]; then
        cp -f "$src" "$target"
        log "[ok] staged $fname (from $WORKFLOWS_SRC_DIR)"
      elif [ -n "$fallback_url" ]; then
        log "[dl] $fname (repo copy missing — falling back to $fallback_url)"
        curl -fsSL -H "Authorization: Bearer ${HF_TOKEN:-}" -H "Accept-Encoding: identity" -o "$target" "$fallback_url"
        log "[ok] downloaded $fname"
      else
        warn "Workflow $fname not found at $src and no fallback URL — skipped"
      fi
    done
  fi

  # --- ComfyUI UI preferences (panel layout, queue sidebar, theme, etc.).
  #     Only seeds the file on fresh install — never overwrites user edits
  #     unless FORCE_RESTAGE=1 is set. Set SETTINGS_SRC in your config to
  #     point elsewhere if needed. ---
  SETTINGS_FILE="${SETTINGS_FILE:-comfy.settings.json}"
  SETTINGS_SRC="${SETTINGS_SRC:-$WORKFLOWS_SRC_DIR/$SETTINGS_FILE}"
  SETTINGS_DEST="$COMFYUI_DIR/user/default/$SETTINGS_FILE"
  if [ -f "$SETTINGS_SRC" ] && { [ ! -f "$SETTINGS_DEST" ] || [ "${FORCE_RESTAGE:-0}" = "1" ]; }; then
    cp "$SETTINGS_SRC" "$SETTINGS_DEST"
    log "[ok] seeded $SETTINGS_DEST from $SETTINGS_SRC"
  elif [ -f "$SETTINGS_DEST" ]; then
    log "[ok] $SETTINGS_DEST already present — left as-is (FORCE_RESTAGE=1 to override)"
  fi

  # --- Settings hardening: ensure framework defaults are set in
  #     comfy.settings.json without clobbering any user-chosen value.
  #     Keys we enforce ONLY when missing:
  #       Comfy.UseNewMenu = "Top"
  #         → keeps the modern top menu bar visible. This IS ComfyUI's
  #           default; we set it explicitly so the framework's intent is
  #           recorded in the file even if upstream defaults change.
  #           Manager's UI lives in the top menu bar as the puzzle-piece
  #           button — NOT as a floating button in a legacy menu.
  #           Earlier the framework set this to "Disabled" thinking that
  #           would make Manager more discoverable, but that just hid the
  #           entire top bar with no clean Manager replacement.
  #     If the user later sets the value to "Bottom" or "Disabled" via
  #     the UI and saves, that choice is preserved (we only fill in
  #     missing keys). ---
  if [ ! -f "$SETTINGS_DEST" ]; then
    # No seed exists yet — start from an empty JSON object so jq can merge into it
    echo '{}' > "$SETTINGS_DEST"
    log "[ok] created empty $SETTINGS_DEST for settings hardening"
  fi
  ensure_setting() {
    local key="$1" val="$2"
    local current
    if command -v jq >/dev/null 2>&1; then
      current="$(jq -r --arg k "$key" '.[$k] // "_unset"' "$SETTINGS_DEST" 2>/dev/null)"
      if [ "$current" = "_unset" ]; then
        local tmp; tmp="$(mktemp)"
        jq --arg k "$key" --arg v "$val" '. + {($k): $v}' "$SETTINGS_DEST" > "$tmp" && mv "$tmp" "$SETTINGS_DEST"
        log "[settings] added missing $key = \"$val\""
      else
        log "[settings] $key already set to \"$current\" — preserved"
      fi
    else
      # Fallback: python3 (available on every image we target)
      python3 - "$SETTINGS_DEST" "$key" "$val" <<'PY'
import json, sys
path, key, val = sys.argv[1:]
d = json.load(open(path))
if key not in d:
    d[key] = val
    json.dump(d, open(path, 'w'), indent=2)
    print(f'[settings] added missing {key} = "{val}"')
else:
    print(f'[settings] {key} already set to "{d[key]}" — preserved')
PY
    fi
  }
  ensure_setting "Comfy.UseNewMenu" "Top"
else
  banner "Phase 4 — Workflow JSON [SKIPPED]"
fi

# HEAD parse: prefer X-Linked-Size, then Content-Length. Extract X-Linked-Etag (sha256 from HF LFS).
hf_head() {
  local url="$1"
  curl -sI -L -H "Authorization: Bearer $HF_TOKEN" "$url" | awk '
    BEGIN { IGNORECASE=1; size=""; clen=""; etag=""; xetag="" }
    /^X-Linked-Size:/   { size=$2 }
    /^Content-Length:/  { clen=$2 }
    /^X-Linked-Etag:/   { xetag=$2 }
    /^ETag:/            { etag=$2 }
    END {
      gsub(/\r/,"",size); gsub(/\r/,"",clen); gsub(/\r/,"",etag); gsub(/\r/,"",xetag)
      gsub(/"/,"",xetag); gsub(/"/,"",etag)
      out_size = (size != "") ? size : clen
      out_etag = (xetag != "") ? xetag : etag
      printf "%s %s", (out_size+0), out_etag
    }'
}

sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    printf ''
  fi
}

download_model() {
  local rel="$1" url="$2"
  local target="$MODELS/$rel"
  local partial="$target.partial"
  mkdir -p "$(dirname "$target")"

  local head_out expected_size expected_etag
  head_out="$(hf_head "$url" || true)"
  expected_size="$(printf '%s' "$head_out" | awk '{print $1}')"
  expected_etag="$(printf '%s' "$head_out" | awk '{print $2}')"
  expected_size="${expected_size:-0}"

  local local_size
  local_size="$(filesize "$target")"

  if [ "$expected_size" -gt 0 ] && [ "$local_size" = "$expected_size" ]; then
    if [ "${VERIFY_HASHES:-0}" = "1" ] && [ -n "$expected_etag" ]; then
      log "[verify] $rel — computing sha256"
      got="$(sha256_of "$target")"
      if [ -n "$got" ] && [ "$got" != "$expected_etag" ]; then
        log "[bad-hash] $rel  expected=$expected_etag got=$got — redownloading"
        rm -f "$target"
      else
        log "[ok] $rel (verified, $local_size bytes)"
        return 0
      fi
    else
      log "[ok] $rel ($local_size bytes)"
      return 0
    fi
  fi

  local attempt=0
  local delays=(10 20 30 60 90)
  local max=5
  while [ "$attempt" -lt "$max" ]; do
    attempt=$((attempt + 1))
    local partial_size
    partial_size="$(filesize "$partial")"
    if [ -f "$partial" ] && [ "$expected_size" -gt 0 ] && [ "$partial_size" -lt "$expected_size" ]; then
      log "[resume] $rel attempt $attempt/$max (partial=$partial_size, expected=$expected_size)"
      curl -fL --retry 0 -C - -H "Authorization: Bearer $HF_TOKEN" -o "$partial" "$url" || warn "resume failed for $rel"
    else
      log "[dl] $rel attempt $attempt/$max (expected=$expected_size)"
      curl -fL --retry 0 -H "Authorization: Bearer $HF_TOKEN" -o "$partial" "$url" || warn "download failed for $rel"
    fi

    local got_size
    got_size="$(filesize "$partial")"
    if [ "$expected_size" -gt 0 ] && [ "$got_size" = "$expected_size" ]; then
      if [ "${VERIFY_HASHES:-0}" = "1" ] && [ -n "$expected_etag" ]; then
        got="$(sha256_of "$partial")"
        if [ -n "$got" ] && [ "$got" != "$expected_etag" ]; then
          log "[bad-hash] $rel  expected=$expected_etag got=$got — retrying"
          rm -f "$partial"
        else
          mv "$partial" "$target"
          log "[ok] $rel ($got_size bytes, verified)"
          return 0
        fi
      else
        mv "$partial" "$target"
        log "[ok] $rel ($got_size bytes)"
        return 0
      fi
    elif [ "$expected_size" -eq 0 ] && [ "$got_size" -gt 0 ]; then
      mv "$partial" "$target"
      log "[ok] $rel ($got_size bytes, unknown expected size)"
      return 0
    fi

    local idx=$((attempt - 1))
    local delay="${delays[$idx]:-90}"
    warn "$rel attempt $attempt failed; sleeping ${delay}s"
    sleep "$delay"
  done

  err "$rel failed after $max attempts"
  return 1
}

# ---------- Civitai download helper (sha256-verified, resumable) ----------
# Civitai's /api/download/models/<id> 302-redirects to a presigned CDN URL; the
# token rides on the original request. We verify by the known sha256 since
# Civitai does not expose a reliable size header.
download_civitai() {
  local rel="$1" url="$2" expected_sha="$3"
  local target="$MODELS/$rel"
  local partial="$target.partial"
  mkdir -p "$(dirname "$target")"

  if [ -f "$target" ]; then
    if [ -n "$expected_sha" ]; then
      local got
      got="$(sha256_of "$target")"
      if [ -n "$got" ] && [ "$got" = "$expected_sha" ]; then
        log "[ok] $rel (verified)"
        return 0
      fi
      log "[bad-hash] $rel — redownloading"
      rm -f "$target"
    else
      log "[ok] $rel (present, no hash to verify)"
      return 0
    fi
  fi

  local attempt=0
  local delays=(10 20 30 60 90)
  local max=5
  while [ "$attempt" -lt "$max" ]; do
    attempt=$((attempt + 1))
    log "[dl] $rel attempt $attempt/$max (civitai)"
    if [ -f "$partial" ]; then
      curl -fL --retry 0 -C - -H "Authorization: Bearer $CIVITAI_API_KEY" -o "$partial" "$url" || warn "resume failed for $rel"
    else
      curl -fL --retry 0 -H "Authorization: Bearer $CIVITAI_API_KEY" -o "$partial" "$url" || warn "download failed for $rel"
    fi

    local got_size
    got_size="$(filesize "$partial")"
    if [ "$got_size" -gt 0 ]; then
      if [ -n "$expected_sha" ]; then
        local got
        got="$(sha256_of "$partial")"
        if [ -n "$got" ] && [ "$got" != "$expected_sha" ]; then
          warn "$rel sha mismatch (got=$got) — retrying"
          rm -f "$partial"
        else
          mv "$partial" "$target"
          log "[ok] $rel ($got_size bytes, verified)"
          return 0
        fi
      else
        mv "$partial" "$target"
        log "[ok] $rel ($got_size bytes)"
        return 0
      fi
    fi

    local idx=$((attempt - 1))
    local delay="${delays[$idx]:-90}"
    warn "$rel attempt $attempt failed; sleeping ${delay}s"
    sleep "$delay"
  done
  err "$rel failed after $max attempts"
  return 1
}

if [ "${SKIP_MODELS:-0}" != "1" ]; then
  banner "Phase 5 — Models"
  for entry in "${MODEL_MAP[@]}"; do
    rel="${entry%%|*}"
    url="${entry#*|}"
    download_model "$rel" "$url"
  done

  # --- Civitai downloads (needs CIVITAI_API_KEY; sha256-verified) ---
  if [ -n "${CIVITAI_API_KEY:-}" ]; then
    for entry in "${MODEL_MAP_CIVITAI[@]}"; do
      IFS='|' read -r rel civurl sha <<<"$entry"
      download_civitai "$rel" "$civurl" "$sha"
    done
  else
    [ "${#MODEL_MAP_CIVITAI[@]}" -gt 0 ] && warn "CIVITAI_API_KEY unset — skipping ${#MODEL_MAP_CIVITAI[@]} Civitai download(s)"
  fi

else
  banner "Phase 5 — Models [SKIPPED]"
fi

# ---------- Phase 6 — Update All ----------
if [ "${SKIP_UPDATE_ALL:-0}" != "1" ]; then
  banner "Phase 6 — Update All"

  declare -A PINNED=()
  for entry in "${NODE_MAP[@]}"; do
    IFS='|' read -r _repo _pin _folder _extra <<<"$entry"
    if [ -n "$_pin" ]; then
      PINNED["$_folder"]=1
    fi
  done

  if [ -d "$COMFYUI_DIR/.git" ]; then
    log "[pull] ComfyUI core"
    git -C "$COMFYUI_DIR" fetch --unshallow 2>/dev/null || true
    if git -C "$COMFYUI_DIR" pull --ff-only --quiet 2>/dev/null; then
      if [ -f "$COMFYUI_DIR/requirements.txt" ]; then
        "$COMFY_PIP" install -q -r "$COMFYUI_DIR/requirements.txt" || warn "core requirements install failed"
      fi
    else
      log "[skip] ComfyUI core pull (non-ff or no remote changes)"
    fi
  else
    log "[skip] ComfyUI core (not a git repo)"
  fi

  for d in "$CUSTOM_NODES"/*/.git; do
    [ -e "$d" ] || continue
    nodedir="$(dirname "$d")"
    name="$(basename "$nodedir")"
    if [ -n "${PINNED[$name]:-}" ]; then
      log "[pin] $name (skipping update)"
      continue
    fi
    log "[pull] $name"
    git -C "$nodedir" fetch --unshallow 2>/dev/null || true
    if git -C "$nodedir" pull --ff-only --quiet 2>/dev/null; then
      if [ -f "$nodedir/requirements.txt" ]; then
        "$COMFY_PIP" install -q -r "$nodedir/requirements.txt" || warn "requirements install failed for $name"
      fi
    else
      log "[skip] $name pull (non-ff or no remote changes)"
    fi
  done
else
  banner "Phase 6 — Update All [SKIPPED]"
fi

# ---------- Phase 7 — Restart ----------
if [ "${SKIP_RESTART:-0}" != "1" ]; then
  banner "Phase 7 — Restart"
  if [ "$HAS_SUPERVISOR" = "1" ]; then
    log "Restarting comfyui via supervisorctl"
    supervisorctl restart comfyui || warn "supervisorctl restart failed"
    log "Polling http://127.0.0.1:$COMFY_PORT/ ..."
    ok=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$COMFY_PORT/" 2>/dev/null | grep -q '^200$'; then
        log "[ok] ComfyUI responded HTTP 200 on attempt $i"
        ok=1
        break
      fi
      sleep 3
    done
    [ "$ok" = "1" ] || warn "ComfyUI did not respond with HTTP 200 within 30s"
  else
    log "No supervisor detected. Launch ComfyUI manually:"
    if [ "$PLATFORM" = "Darwin" ]; then
      printf '  cd %s && source .venv/bin/activate && python main.py --listen 127.0.0.1 --port %s --enable-cors-header --enable-manager\n' \
        "$COMFYUI_DIR" "$COMFY_PORT"
    else
      printf '  cd %s && python main.py --listen 0.0.0.0 --port %s --enable-cors-header --enable-manager\n' \
        "$COMFYUI_DIR" "$COMFY_PORT"
    fi
  fi
else
  banner "Phase 7 — Restart [SKIPPED]"
fi

banner "Done"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s/%s\n' "$SCRIPT_DIR" "$(basename "${BASH_SOURCE[0]}")"
