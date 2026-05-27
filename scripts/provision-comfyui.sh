#!/usr/bin/env bash
# provision-comfyui.sh
# Provision a ComfyUI workspace for four workflows in one pass:
#   1. "10Eros LikenessGuide I2V v3.2"  (LTX-2.3 video)
#   2. "BFS - Best Face Swap" on Flux.2 Klein 9B  (Civitai 2027766 / v2610018)
#   3. "10Eros 10S + MrXin Joined I2V v1"  (LTX-2.3 video; 10S likeness chain +
#      MrXin V6.1 RIFE interpolation + VRAM/RAM cleanup + JoyCaption uncensored
#      VLM captioning (replaces QwenVL). Reuses #1's video models.)
#   4. "Qwen Edit then 10Eros MrXin I2V v1"  (combined: Qwen Image Edit Rapid
#      AIO -> JoyCaption -> MrXin I2V; reuses all models from #2 + #3.)
# Idempotent: safe to re-run, resumes interrupted downloads.
# Supports: macOS (~/comfyui) and Linux (RunPod/Vast.ai worker-comfyui at /workspace/ComfyUI).
#
# Target VastAI image: vastai/comfy:v0.22.0-cuda-12.9-py312  (Ubuntu 24.04, Py 3.12, ComfyUI v0.22.0)
# Recommended GPU:     RTX 4090 (24 GB VRAM). Disk: ~150 GB after models download.

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
[ -n "${GH_TOKEN:-}" ]         && log "GH_TOKEN: $(mask "$GH_TOKEN")"         || log "GH_TOKEN: (unset)"
[ -n "${CIVITAI_API_KEY:-}" ]  && log "CIVITAI_API_KEY: $(mask "$CIVITAI_API_KEY")" || log "CIVITAI_API_KEY: (unset)"

# ---------- Config (NODE_MAP, ALIAS_MAP, MODEL_MAP, MODEL_MAP_CIVITAI, WORKFLOW_MAP) ----------
# This provisioner is generic — the stack-specific lists live in an external
# config file. Set PROVISIONER_CONFIG to its path, e.g.:
#   PROVISIONER_CONFIG=/workspace/your-stack-repo/provisioner-config.sh
# If unset, looks for $SCRIPT_DIR/../../provisioner-config.sh (parent repo convention).
SCRIPT_DIR_EARLY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER_CONFIG="${PROVISIONER_CONFIG:-$SCRIPT_DIR_EARLY/../../provisioner-config.sh}"
if [ -f "$PROVISIONER_CONFIG" ]; then
  log "PROVISIONER_CONFIG: $PROVISIONER_CONFIG"
  # shellcheck disable=SC1090
  source "$PROVISIONER_CONFIG"
else
  warn "PROVISIONER_CONFIG not found at $PROVISIONER_CONFIG — NODE_MAP/MODEL_MAP* must be set in the environment or Phases 3, 4, 5 will be no-ops."
fi

# Detect COMFYUI_DIR — check known install locations across common images.
# vastai/comfy installs at /opt/workspace-internal/ComfyUI (with /workspace
# as a separate persistent volume); worker-comfyui and bare RunPod images
# use /workspace/ComfyUI; macOS dev uses ~/comfyui.
COMFYUI_CANDIDATES=(
  "/opt/workspace-internal/ComfyUI"
  "/workspace/ComfyUI"
  "/comfyui"
  "$HOME/comfyui"
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
  "$MODELS"/loras/ltx23 \
  "$MODELS"/loras/Klein \
  "$WORKFLOWS" \
  "$(dirname "$MANAGER_CFG")"

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

# Inject x-access-token for github clones when GH_TOKEN set
git_auth_url() {
  local url="$1"
  if [ -n "${GH_TOKEN:-}" ] && [[ "$url" == https://github.com/* ]]; then
    printf 'https://x-access-token:%s@github.com/%s' "$GH_TOKEN" "${url#https://github.com/}"
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
if [ "$PLATFORM" = "Linux" ] && [ -f /etc/environment ]; then
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
if [ "$PLATFORM" = "Linux" ] && [ -f /etc/environment ]; then
  TOKEN_FILE="/etc/environment"
else
  TOKEN_FILE="$HOME/.comfyui-tokens.env"
  [ -f "$TOKEN_FILE" ] || { : > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; }
fi
log "Persisting tokens to $TOKEN_FILE"
[ -n "${HF_TOKEN:-}" ]        && upsert_kv "$TOKEN_FILE" "HF_TOKEN"        "$HF_TOKEN"
[ -n "${GH_TOKEN:-}" ]        && upsert_kv "$TOKEN_FILE" "GH_TOKEN"        "$GH_TOKEN"
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

  if [ "${#WORKFLOW_MAP[@]:-0}" -eq 0 ]; then
    warn "WORKFLOW_MAP is empty — define it in your PROVISIONER_CONFIG to stage workflows. Skipping Phase 4."
  else
    for entry in "${WORKFLOW_MAP[@]}"; do
      [ -z "$entry" ] && continue
      IFS="|" read -r fname fallback_url <<<"$entry"
      target="$WORKFLOWS/$fname"
      src="$WORKFLOWS_SRC_DIR/$fname"
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
  #     Only seeds the file on fresh install — never overwrite a user-modified
  #     copy. Set SETTINGS_SRC in your config to point elsewhere if needed. ---
  SETTINGS_FILE="${SETTINGS_FILE:-comfy.settings.json}"
  SETTINGS_SRC="${SETTINGS_SRC:-$WORKFLOWS_SRC_DIR/$SETTINGS_FILE}"
  SETTINGS_DEST="$COMFYUI_DIR/user/default/$SETTINGS_FILE"
  if [ -f "$SETTINGS_SRC" ] && [ ! -f "$SETTINGS_DEST" ]; then
    cp "$SETTINGS_SRC" "$SETTINGS_DEST"
    log "[ok] seeded $SETTINGS_DEST from $SETTINGS_SRC"
  elif [ -f "$SETTINGS_DEST" ]; then
    log "[ok] $SETTINGS_DEST already present — left as-is"
  fi
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

  legacy_dup="$MODELS/loras/ltx-2.3-22b-distilled-lora-1.1_fro90_ceil72_condsafe.safetensors"
  if [ -f "$legacy_dup" ]; then
    log "[rename] removing legacy duplicate $legacy_dup"
    rm -f "$legacy_dup"
  fi

  # --- BFS face-swap LoRA from Civitai (needs CIVITAI_API_KEY) ---
  if [ -n "${CIVITAI_API_KEY:-}" ]; then
    for entry in "${MODEL_MAP_CIVITAI[@]}"; do
      IFS='|' read -r rel civurl sha <<<"$entry"
      download_civitai "$rel" "$civurl" "$sha"
    done
  else
    warn "CIVITAI_API_KEY unset — skipping BFS face-swap LoRA download"
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
