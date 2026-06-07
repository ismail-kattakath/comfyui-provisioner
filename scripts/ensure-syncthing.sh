#!/usr/bin/env bash
# scripts/ensure-syncthing.sh
#
# Idempotent Syncthing wiring between the devcontainer and a VastAI instance.
# New policy: the Mac host NEVER runs Syncthing — all wiring is container-side.
#
# Usage:
#   ensure-syncthing.sh [STACK_DIR|STACK_NAME] [INSTANCE_ID]
#   ensure-syncthing.sh --check   [STACK_DIR|STACK_NAME] [INSTANCE_ID]
#   ensure-syncthing.sh --troubleshoot [STACK_DIR|STACK_NAME] [INSTANCE_ID]
#
# Flags:
#   --check           Report only; no mutations.
#   --troubleshoot    Verbose diagnosis: daemon, devices, folders, connection, conflicts.
#
# Instance resolution order:
#   1. Explicit INSTANCE_ID argument
#   2. Marker file <stack>/.syncthing-instance
#   3. Auto-detect: exactly one running vastai instance (warn+skip if 0 or >1)
#
# Exit codes:
#   0  wired & healthy (idempotent no-op when already correct)
#   2  healed or needs attention (e.g. >1 running instance, unknown folder suffix)
#   1  hard failure (can't reach instance, daemon won't start)
#
# Folder suffix → local subdir mapping:
#   *-logs       → logs/      (receiveonly)
#   *-workflows  → comfyui/   (receiveonly)
#   (unknown suffix → warn, skip, exit 2)
#
# Syncthing config: /comfy/.syncthing (persistent named volume; stable device ID)
# GUI/REST:         127.0.0.1:18384
# Instance REST:    127.0.0.1:18384 (NOT 8384 — that's Caddy auth proxy)
# Instance binary:  /opt/syncthing/syncthing
# Instance config:  /opt/syncthing/config/config.xml

set -euo pipefail

# ── constants ────────────────────────────────────────────────────────────────
CFG="${SYNCTHING_CONFIG_DIR:-/comfy/.syncthing}"
GUI="127.0.0.1:18384"
MARKER=".syncthing-instance"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── mode flags ────────────────────────────────────────────────────────────────
MODE=heal        # heal | check | troubleshoot
STACK_ARG=""
INSTANCE_ARG=""

for arg in "$@"; do
  case "$arg" in
    --check)        MODE=check ;;
    --troubleshoot) MODE=troubleshoot ;;
    --*)            echo "[ensure-syncthing] unknown flag: $arg" >&2; exit 1 ;;
    *)
      if [[ -z "$STACK_ARG" ]]; then STACK_ARG="$arg"
      elif [[ -z "$INSTANCE_ARG" ]]; then INSTANCE_ARG="$arg"
      fi
      ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────
die()  { echo "[ensure-syncthing] [ERROR] $*" >&2; exit 1; }
log()  { printf '[ensure-syncthing] %s\n' "$*"; }
info() { printf '[ensure-syncthing] [info] %s\n' "$*"; }
warn() { printf '[ensure-syncthing] [WARN] %s\n' "$*" >&2; }

trap 'echo "[ensure-syncthing] [ERROR] unexpected failure at line $LINENO" >&2' ERR

# ── resolve stack dir ─────────────────────────────────────────────────────────
resolve_stack() {
  local a="$1"
  if [[ -z "$a" ]]; then
    [[ -d "$PWD/comfyui" ]] && { printf '%s\n' "$PWD"; return; }
    return 1
  fi
  [[ -d "$a/comfyui" ]]                              && { printf '%s\n' "$a"; return; }
  [[ -d "/workspaces/$a/comfyui" ]]                  && { printf '%s\n' "/workspaces/$a"; return; }
  [[ -d "/workspaces/comfyui-stack-$a/comfyui" ]]    && { printf '%s\n' "/workspaces/comfyui-stack-$a"; return; }
  return 1
}

STACK_DIR="$(resolve_stack "$STACK_ARG")" || {
  echo "[ensure-syncthing] could not find a stack with comfyui/ for '${STACK_ARG:-<cwd>}'" >&2
  echo "                   pass a stack path or name, e.g.: ensure-syncthing.sh iclight-v2v" >&2
  exit 1
}
STACK_NAME="$(basename "$STACK_DIR")"
log "stack: $STACK_DIR"

# ── folder suffix → local path mapping ───────────────────────────────────────
# Returns: "local_subdir:type" for a folder id, empty string if unknown.
map_folder_suffix() {
  local id="$1"
  case "$id" in
    *-logs)      printf '%s\n' "logs/:receiveonly" ;;
    *-workflows) printf '%s\n' "comfyui/:receiveonly" ;;
    *-output)    printf '%s\n' "output/:receiveonly" ;;
    *-input)     printf '%s\n' "input/:sendonly" ;;
    *)           printf '' ;;
  esac
}

# ── resolve instance id ───────────────────────────────────────────────────────
INSTANCE_ID=""
INSTANCE_SRC=""

if [[ -n "$INSTANCE_ARG" ]]; then
  INSTANCE_ID="$INSTANCE_ARG"
  INSTANCE_SRC="argument"
elif [[ -f "$STACK_DIR/$MARKER" ]]; then
  INSTANCE_ID="$(cat "$STACK_DIR/$MARKER" | tr -d '[:space:]')"
  INSTANCE_SRC="marker file ($STACK_DIR/$MARKER)"
else
  # auto-detect: exactly one running instance
  if command -v vastai >/dev/null 2>&1; then
    RUNNING_IDS="$(vastai show instances 2>/dev/null \
      | python3 -c "
import sys, json
lines = sys.stdin.read().strip().split('\n')
# vastai show instances output: space-separated; first col is ID, check actual_status
ids = []
for line in lines[1:]:  # skip header
    cols = line.split()
    if len(cols) >= 2:
        # actual_status is typically col index varies; use json api instead
        ids.append(cols[0])
for i in ids:
    print(i)
" 2>/dev/null || true)"
    # use the JSON API for reliable status
    if command -v python3 >/dev/null 2>&1 && [[ -n "${VAST_API_KEY:-}" ]]; then
      RUNNING_IDS="$(python3 -c "
import urllib.request, json, os
req = urllib.request.Request('https://console.vast.ai/api/v0/instances/',
  headers={'Authorization': 'Bearer ' + os.environ['VAST_API_KEY']})
data = json.loads(urllib.request.urlopen(req, timeout=10).read())
for inst in data.get('instances', []):
    if inst.get('actual_status') == 'running':
        print(inst['id'])
" 2>/dev/null || true)"
    fi
    IDS_COUNT="$(printf '%s\n' "$RUNNING_IDS" | grep -c '[0-9]' || true)"
    if [[ "$IDS_COUNT" -eq 1 ]]; then
      INSTANCE_ID="$(printf '%s\n' "$RUNNING_IDS" | grep '[0-9]' | head -1)"
      INSTANCE_SRC="auto-detect (sole running instance)"
    elif [[ "$IDS_COUNT" -eq 0 ]]; then
      info "no running VastAI instances found — nothing to wire"
      echo "[ensure-syncthing] VERDICT: no vastai target — nothing to wire (exit 0)"
      exit 0
    else
      warn "multiple running VastAI instances ($IDS_COUNT) — cannot auto-detect; pass INSTANCE_ID explicitly"
      echo "[ensure-syncthing] VERDICT: ambiguous — multiple instances running (exit 2)"
      exit 2
    fi
  else
    info "vastai CLI not available and no marker file — nothing to wire"
    echo "[ensure-syncthing] VERDICT: no vastai target — nothing to wire (exit 0)"
    exit 0
  fi
fi

log "instance: $INSTANCE_ID (from $INSTANCE_SRC)"

# ── check syncthing binary ────────────────────────────────────────────────────
command -v syncthing >/dev/null 2>&1 || \
  die "syncthing not installed. Rebuild the devcontainer or: sudo apt-get install -y syncthing"

# ── start / ensure container daemon ──────────────────────────────────────────
mkdir -p "$CFG"

if ! pgrep -x syncthing >/dev/null 2>&1; then
  if [[ "$MODE" = check ]]; then
    warn "container syncthing daemon not running (--check mode; skipping start)"
  else
    log "starting container syncthing daemon (config: $CFG)"
    nohup syncthing serve --home="$CFG" --no-browser --no-restart \
      --gui-address="$GUI" >/tmp/syncthing-container.log 2>&1 &
    # wait for API key to appear (config.xml written on first start)
    for _ in $(seq 1 30); do
      [[ -f "$CFG/config.xml" ]] && grep -q '<apikey>' "$CFG/config.xml" && break
      sleep 1
    done
  fi
fi

# read API key — AFTER daemon started (cert is lazy; --device-id before daemon = cert.pem error)
ST_APIKEY=""
for _ in $(seq 1 30); do
  ST_APIKEY="$(grep -oP '(?<=<apikey>)[^<]+' "$CFG/config.xml" 2>/dev/null | head -1 || true)"
  [[ -n "$ST_APIKEY" ]] && break
  sleep 1
done

st() { syncthing cli --gui-address="$GUI" --gui-apikey="$ST_APIKEY" "$@"; }

if [[ -n "$ST_APIKEY" ]]; then
  # wait for REST to be ready
  for _ in $(seq 1 30); do
    st show system >/dev/null 2>&1 && break
    sleep 1
  done
else
  [[ "$MODE" = check ]] || die "container syncthing API never came up (see /tmp/syncthing-container.log)"
fi

# get container device id — ONLY after daemon is up
CONTAINER_DEVICE_ID="$(st show system 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('myID',''))" 2>/dev/null || true)"
[[ -n "$CONTAINER_DEVICE_ID" ]] || \
  [[ "$MODE" = check ]] || \
  die "could not read container device ID from running daemon"
log "container device id: ${CONTAINER_DEVICE_ID:-<unavailable>}"

# ── SSH helpers ───────────────────────────────────────────────────────────────
resolve_ssh() {
  local id="$1"
  local url
  for attempt in 1 2 3; do
    url="$(vastai ssh-url "$id" 2>/dev/null || true)"
    [[ -n "$url" ]] && [[ "${url#ssh://}" != "$url" ]] && { printf '%s\n' "$url"; return 0; }
    sleep 3
  done
  return 1
}

SSH_URL="$(resolve_ssh "$INSTANCE_ID")" || die "could not resolve ssh-url for $INSTANCE_ID (running? SSH agent forwarded?)"
HP="${SSH_URL#ssh://root@}"; SSH_H="${HP%:*}"; SSH_P="${HP##*:}"
SSH=(ssh -p "$SSH_P" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 "root@$SSH_H")
log "instance ssh: root@$SSH_H:$SSH_P"

# ── read instance syncthing state ─────────────────────────────────────────────
INST_RAW=""
INST_RAW="$("${SSH[@]}" '
  ST_KEY=$(grep -oP "(?<=<apikey>)[^<]+" /opt/syncthing/config/config.xml 2>/dev/null | head -1)
  ST(){ /opt/syncthing/syncthing cli --gui-address=127.0.0.1:18384 --gui-apikey="$ST_KEY" "$@"; }
  echo "DEVICE=$(ST show system 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get(\"myID\",\"\"))" 2>/dev/null)"
  # enumerate all folder ids
  FOLDER_IDS=$(ST config folders list 2>/dev/null || true)
  for FID in $FOLDER_IDS; do
    FPATH=$(ST config folders "$FID" path get 2>/dev/null || true)
    FTYPE=$(ST config folders "$FID" type get 2>/dev/null || true)
    echo "FOLDER:$FID:$FPATH:$FTYPE"
  done
' 2>/dev/null)" || die "SSH connection to instance $INSTANCE_ID failed"

INSTANCE_DEVICE_ID="$(printf '%s\n' "$INST_RAW" | sed -n 's/^DEVICE=//p' | head -1)"
[[ -n "$INSTANCE_DEVICE_ID" ]] || die "could not read instance device ID over SSH"
log "instance device id: $INSTANCE_DEVICE_ID"

# parse instance folders into arrays
declare -a INST_FOLDER_IDS=()
declare -A INST_FOLDER_PATHS=()
declare -A INST_FOLDER_TYPES=()
while IFS= read -r line; do
  if [[ "$line" == FOLDER:* ]]; then
    IFS=: read -r _ fid fpath ftype <<< "$line"
    INST_FOLDER_IDS+=("$fid")
    INST_FOLDER_PATHS["$fid"]="$fpath"
    INST_FOLDER_TYPES["$fid"]="$ftype"
  fi
done <<< "$INST_RAW"

log "instance folders: ${INST_FOLDER_IDS[*]:-<none>}"

# ── troubleshoot mode: full diagnosis ────────────────────────────────────────
if [[ "$MODE" = troubleshoot ]]; then
  echo
  echo "== Troubleshoot: $STACK_NAME / instance $INSTANCE_ID =="
  echo
  echo "-- Container daemon --"
  pgrep -x syncthing >/dev/null 2>&1 && echo "  running: yes" || echo "  running: NO"
  echo "  config dir: $CFG"
  echo "  API key: ${ST_APIKEY:+set}"
  echo "  device id: ${CONTAINER_DEVICE_ID:-<unavailable>}"
  echo
  echo "-- Container folders --"
  if [[ -n "$ST_APIKEY" ]]; then
    st config folders list 2>/dev/null | while read -r fid; do
      fpath="$(st config folders "$fid" path get 2>/dev/null || echo '?')"
      ftype="$(st config folders "$fid" type get 2>/dev/null || echo '?')"
      echo "  $fid  path=$fpath  type=$ftype"
    done || echo "  <none>"
  else
    echo "  <daemon not available>"
  fi
  echo
  echo "-- Instance folders --"
  for fid in "${INST_FOLDER_IDS[@]:-}"; do
    echo "  $fid  path=${INST_FOLDER_PATHS[$fid]:-?}  type=${INST_FOLDER_TYPES[$fid]:-?}"
  done
  echo
  echo "-- Connection state --"
  if [[ -n "$ST_APIKEY" ]] && [[ -n "$INSTANCE_DEVICE_ID" ]]; then
    CONN="$(st show connections 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
dev = '$INSTANCE_DEVICE_ID'
c = d.get('connections', {}).get(dev, {})
print('connected:', c.get('connected', False))
print('address:', c.get('address', 'none'))
" 2>/dev/null || echo "  <unavailable>")"
    echo "$CONN" | sed 's/^/  /'
  else
    echo "  <daemon not available>"
  fi
  echo
  echo "-- Per-folder sync errors --"
  if [[ -n "$ST_APIKEY" ]]; then
    st show folderstate 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for fid, s in d.items():
    errors = s.get('errors', 0)
    state = s.get('state', '?')
    print(f'  {fid}: state={state} errors={errors}')
" 2>/dev/null || echo "  <unavailable>"
  fi
  echo
  echo "-- Sync-conflict files --"
  for fid in "${INST_FOLDER_IDS[@]:-}"; do
    mapping="$(map_folder_suffix "$fid")"
    [[ -z "$mapping" ]] && continue
    subdir="${mapping%%:*}"
    local_path="$STACK_DIR/$subdir"
    if [[ -d "$local_path" ]]; then
      CONFLICTS="$(find "$local_path" -name '*.sync-conflict-*' 2>/dev/null | head -10 || true)"
      if [[ -n "$CONFLICTS" ]]; then
        warn "conflict files in $local_path:"
        printf '%s\n' "$CONFLICTS" | sed 's/^/    /'
      fi
    fi
  done
  echo
fi

# ── main reconciliation ───────────────────────────────────────────────────────
EXIT_CODE=0
HEALED=0

for FOLDER_ID in "${INST_FOLDER_IDS[@]:-}"; do
  INST_PATH="${INST_FOLDER_PATHS[$FOLDER_ID]:-}"
  INST_TYPE="${INST_FOLDER_TYPES[$FOLDER_ID]:-}"

  MAPPING="$(map_folder_suffix "$FOLDER_ID")"
  if [[ -z "$MAPPING" ]]; then
    warn "unknown folder suffix for '$FOLDER_ID' (path=$INST_PATH) — skipping; add a mapping if needed"
    EXIT_CODE=2
    continue
  fi

  LOCAL_SUBDIR="${MAPPING%%:*}"
  LOCAL_TYPE="${MAPPING##*:}"
  LOCAL_PATH="$STACK_DIR/$LOCAL_SUBDIR"
  mkdir -p "$LOCAL_PATH"

  log "folder $FOLDER_ID: instance=$INST_PATH ($INST_TYPE) -> local=$LOCAL_PATH ($LOCAL_TYPE)"

  if [[ "$MODE" = check ]]; then
    # check only — no mutations
    if [[ -n "$ST_APIKEY" ]]; then
      HAS_FOLDER="$(st config folders list 2>/dev/null | grep -cF "$FOLDER_ID" || true)"
      if [[ "$HAS_FOLDER" -eq 0 ]]; then
        warn "container missing folder $FOLDER_ID (needs heal)"
        EXIT_CODE=2
      else
        CURRENT_PATH="$(st config folders "$FOLDER_ID" path get 2>/dev/null || true)"
        CURRENT_TYPE="$(st config folders "$FOLDER_ID" type get 2>/dev/null || true)"
        if [[ "$CURRENT_PATH" != "$LOCAL_PATH" ]]; then
          warn "folder $FOLDER_ID path mismatch: got=$CURRENT_PATH want=$LOCAL_PATH (needs heal)"
          EXIT_CODE=2
        fi
        if [[ "$CURRENT_TYPE" != "$LOCAL_TYPE" ]]; then
          warn "folder $FOLDER_ID type mismatch: got=$CURRENT_TYPE want=$LOCAL_TYPE (needs heal)"
          EXIT_CODE=2
        fi
      fi
    fi
    continue
  fi

  # ── heal: ensure container folder ─────────────────────────────────────────
  # Remove default junk folder if present
  if st config folders list 2>/dev/null | grep -qxF "default"; then
    log "removing default junk folder from container"
    st config folders default delete >/dev/null 2>&1 || true
    HEALED=1
  fi

  HAS_FOLDER="$(st config folders list 2>/dev/null | grep -cF "$FOLDER_ID" || true)"
  if [[ "$HAS_FOLDER" -eq 0 ]]; then
    log "adding container folder $FOLDER_ID -> $LOCAL_PATH ($LOCAL_TYPE)"
    st config folders add --id "$FOLDER_ID" --label "$FOLDER_ID (container)" \
      --path "$LOCAL_PATH" --type "$LOCAL_TYPE"
    HEALED=1
  else
    # fix wrong path or type
    CURRENT_PATH="$(st config folders "$FOLDER_ID" path get 2>/dev/null || true)"
    CURRENT_TYPE="$(st config folders "$FOLDER_ID" type get 2>/dev/null || true)"
    if [[ "$CURRENT_PATH" != "$LOCAL_PATH" ]]; then
      log "correcting folder $FOLDER_ID path: $CURRENT_PATH -> $LOCAL_PATH"
      st config folders "$FOLDER_ID" path set "$LOCAL_PATH"
      HEALED=1
    fi
    if [[ "$CURRENT_TYPE" != "$LOCAL_TYPE" ]]; then
      log "correcting folder $FOLDER_ID type: $CURRENT_TYPE -> $LOCAL_TYPE"
      st config folders "$FOLDER_ID" type set "$LOCAL_TYPE"
      HEALED=1
    fi
  fi

  # ── heal: ensure instance device shared on this folder ────────────────────
  if ! st config folders "$FOLDER_ID" devices list 2>/dev/null | grep -qF "$INSTANCE_DEVICE_ID"; then
    log "sharing folder $FOLDER_ID with instance device"
    st config folders "$FOLDER_ID" devices add --device-id "$INSTANCE_DEVICE_ID"
    HEALED=1
  fi

  # ── heal: ensure container device added to container ──────────────────────
  if ! st config devices list 2>/dev/null | grep -qF "$INSTANCE_DEVICE_ID"; then
    log "adding instance device to container"
    st config devices add --device-id "$INSTANCE_DEVICE_ID" --name "vastai-$INSTANCE_ID"
    st config devices "$INSTANCE_DEVICE_ID" compression set always 2>/dev/null || true
    HEALED=1
  fi

  # ── heal: instance side (via SSH) ─────────────────────────────────────────
  CONTAINER_DEV="${CONTAINER_DEVICE_ID:-}"
  if [[ -n "$CONTAINER_DEV" ]]; then
    INST_HEAL_OUT="$("${SSH[@]}" "
      ST_KEY=\$(grep -oP '(?<=<apikey>)[^<]+' /opt/syncthing/config/config.xml | head -1)
      ST(){ /opt/syncthing/syncthing cli --gui-address=127.0.0.1:18384 --gui-apikey=\"\$ST_KEY\" \"\$@\"; }
      HEALED=0
      if ! ST config devices list 2>/dev/null | grep -qF '$CONTAINER_DEV'; then
        ST config devices add --device-id '$CONTAINER_DEV' --name 'devcontainer-${STACK_NAME}' >/dev/null
        echo 'HEALED:added-device'
      fi
      if ! ST config folders '$FOLDER_ID' devices list 2>/dev/null | grep -qF '$CONTAINER_DEV'; then
        ST config folders '$FOLDER_ID' devices add --device-id '$CONTAINER_DEV' >/dev/null
        echo 'HEALED:added-folder-share'
      fi
    " 2>/dev/null || true)"
    if printf '%s\n' "$INST_HEAL_OUT" | grep -q '^HEALED:'; then
      log "instance side healed: $(printf '%s\n' "$INST_HEAL_OUT" | grep '^HEALED:' | tr '\n' ' ')"
      HEALED=1
    fi
  fi
done

# ── record instance id to marker file ────────────────────────────────────────
if [[ "$MODE" != check ]]; then
  if [[ ! -f "$STACK_DIR/$MARKER" ]] || [[ "$(cat "$STACK_DIR/$MARKER" | tr -d '[:space:]')" != "$INSTANCE_ID" ]]; then
    printf '%s\n' "$INSTANCE_ID" > "$STACK_DIR/$MARKER"
    log "recorded instance id $INSTANCE_ID to $STACK_DIR/$MARKER"
  fi
fi

# ── verify: connection + folder health ───────────────────────────────────────
CONNECTED=no
FOLDER_ERRORS=0

if [[ -n "${ST_APIKEY:-}" ]] && [[ -n "$INSTANCE_DEVICE_ID" ]]; then
  log "waiting for connection (up to 60s)..."
  for _ in $(seq 1 30); do
    CONN_STATE="$(st show connections 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d.get('connections', {}).get('$INSTANCE_DEVICE_ID', {})
print('yes' if c.get('connected') else 'no')
" 2>/dev/null || echo no)"
    [[ "$CONN_STATE" = yes ]] && { CONNECTED=yes; break; }
    sleep 2
  done

  FOLDER_ERRORS="$(st show folderstate 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
total = sum(v.get('errors', 0) for v in d.values())
print(total)
" 2>/dev/null || echo 0)"
fi

# ── final verdict ─────────────────────────────────────────────────────────────
echo
echo "== ensure-syncthing verdict =="
echo "  stack:          $STACK_NAME"
echo "  instance:       $INSTANCE_ID"
echo "  container dev:  ${CONTAINER_DEVICE_ID:-<unavailable>}"
echo "  instance dev:   $INSTANCE_DEVICE_ID"
echo "  connection:     $CONNECTED"
echo "  folder errors:  $FOLDER_ERRORS"
[[ "$HEALED" -eq 1 ]] && echo "  healed:         yes (changes were applied)" \
                       || echo "  healed:         no (already correct)"
echo "  mode:           $MODE"

if [[ "$CONNECTED" = yes ]] && [[ "$FOLDER_ERRORS" -eq 0 ]] && [[ "$EXIT_CODE" -eq 0 ]]; then
  echo
  echo "VERDICT: wired & healthy (exit 0)"
  exit 0
elif [[ "$CONNECTED" = no ]] && [[ "$HEALED" -eq 1 ]]; then
  echo
  echo "VERDICT: healed — daemons may still be in discovery/relay handshake (give it 1-2 min) (exit 2)"
  exit 2
elif [[ "$EXIT_CODE" -ne 0 ]]; then
  echo
  echo "VERDICT: needs attention — see warnings above (exit $EXIT_CODE)"
  exit "$EXIT_CODE"
else
  echo
  echo "VERDICT: wired (connection pending) — run again to confirm (exit 2)"
  exit 2
fi
