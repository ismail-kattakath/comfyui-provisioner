#!/usr/bin/env bash
# scripts/pair-syncthing-container.sh
#
# Container-side Syncthing pairing: starts a Syncthing daemon INSIDE the
# container with a persistent config dir, pairs it with a running VastAI
# instance, and creates a receiveonly folder at the stack's comfyui/ directory.
#
# New policy: the Mac host NEVER runs Syncthing — all wiring is container-side.
# For idempotent auto-healed wiring, prefer scripts/ensure-syncthing.sh.
# Use this script for the initial explicit pair operation.
#
# Uses the VS Code-forwarded SSH agent to reach the instance (no key file needed).
#
# NOTE: If the stack's comfyui/ is on a virtiofs/9p bind-mount, a one-line info
# note is printed and pairing continues — the host never runs Syncthing under
# the new policy, so a bind-mount is not a conflict.
# FORCE=1 is accepted as a no-op for back-compat.
#
# Persistence: the daemon's config (hence its stable device ID) lives at
# $SYNCTHING_CONFIG_DIR (default /comfy/.syncthing — the comfyui_data named volume,
# which survives container rebuilds). Without a persistent config dir the device ID
# would change every rebuild and require re-pairing the instance each time.
#
# Usage:
#   scripts/pair-syncthing-container.sh <INSTANCE_ID> [STACK_DIR|STACK_NAME]
#   Env: SYNCTHING_CONFIG_DIR (default /comfy/.syncthing), FORCE=1 (no-op; back-compat).
#
# Exit codes: 0 paired; 1 error.
set -uo pipefail

INSTANCE_ID="${1:-}"; STACK_ARG="${2:-}"
CFG="${SYNCTHING_CONFIG_DIR:-/comfy/.syncthing}"
[ -n "$INSTANCE_ID" ] || { echo "usage: $0 <INSTANCE_ID> [STACK_DIR|STACK_NAME]"; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die(){ echo "[ERROR] $*" >&2; exit 1; }
log(){ printf '[pair-container] %s\n' "$*"; }

# ---------- resolve stack comfyui dir ----------
resolve_dir() {
  local a="$1"
  if [ -z "$a" ]; then [ -d "$PWD/comfyui" ] && { printf '%s\n' "$PWD/comfyui"; return; }; return 1; fi
  [ -d "$a/comfyui" ] && { printf '%s\n' "$a/comfyui"; return; }
  [ -d "/workspaces/$a/comfyui" ] && { printf '%s\n' "/workspaces/$a/comfyui"; return; }
  [ -d "/workspaces/comfyui-stack-$a/comfyui" ] && { printf '%s\n' "/workspaces/comfyui-stack-$a/comfyui"; return; }
  return 1
}
LOCAL_PATH="$(resolve_dir "$STACK_ARG")" || die "could not resolve stack comfyui/ for '${STACK_ARG:-<cwd>}'"
mkdir -p "$LOCAL_PATH"
log "local folder target: $LOCAL_PATH"

# ---------- NOTE: bind-mount is no longer a conflict (host never runs Syncthing) ----------
FSTYPE="$(findmnt -T "$LOCAL_PATH" -no FSTYPE 2>/dev/null || true)"
case "$FSTYPE" in
  virtiofs|9p|nfs|nfs4|cifs|smb3)
    log "note: comfyui/ is on a host bind-mount (fstype=$FSTYPE) — proceeding; host no longer runs Syncthing."
    ;;
esac
# FORCE=1 accepted as no-op for back-compat
# ---------- ensure syncthing binary ----------
command -v syncthing >/dev/null 2>&1 || die "syncthing not installed. Rebuild the devcontainer
       (install-syncthing postCreate) or: sudo apt-get install -y syncthing"

# ---------- start container daemon with persistent config ----------
mkdir -p "$CFG"
GUI=127.0.0.1:18384
st(){ syncthing cli --gui-address="$GUI" --gui-apikey="$ST_APIKEY" "$@"; }

# device id read from running daemon REST (NOT --device-id flag; cert is lazy before daemon starts)

if ! pgrep -x syncthing >/dev/null 2>&1; then
  log "starting container syncthing daemon (config: $CFG)"
  nohup syncthing serve --home="$CFG" --no-browser --no-restart \
    --gui-address="$GUI" >/tmp/syncthing-container.log 2>&1 &
fi
ST_APIKEY="$(grep -oP '(?<=<apikey>)[^<]+' "$CFG/config.xml" 2>/dev/null | head -1)"
# wait for the API to come up
for _ in $(seq 1 30); do
  ST_APIKEY="${ST_APIKEY:-$(grep -oP '(?<=<apikey>)[^<]+' "$CFG/config.xml" 2>/dev/null | head -1)}"
  [ -n "$ST_APIKEY" ] && st show system >/dev/null 2>&1 && break
  sleep 1
done
[ -n "$ST_APIKEY" ] || die "container syncthing API never came up (see /tmp/syncthing-container.log)"

# get container device id from running daemon REST
CONTAINER_DEVICE_ID="$(st show system 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("myID",""))' 2>/dev/null || true)"
[ -n "$CONTAINER_DEVICE_ID" ] || die "could not read container device id from running daemon"
log "container device id: $CONTAINER_DEVICE_ID"

# ---------- resolve instance SSH (agent-forwarded) ----------
command -v vastai >/dev/null 2>&1 || die "vastai CLI not installed"
URL="$(vastai ssh-url "$INSTANCE_ID" 2>/dev/null)"
[ -n "$URL" ] && [ "${URL#ssh://}" != "$URL" ] || die "could not resolve ssh-url for $INSTANCE_ID (running?)"
HP="${URL#ssh://root@}"; H="${HP%:*}"; P="${HP##*:}"
SSH=(ssh -p "$P" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 "root@$H")
log "instance ssh: root@$H:$P"

# ---------- read instance Syncthing state ----------
INST="$("${SSH[@]}" '
  ST_KEY=${OPEN_BUTTON_TOKEN:-$(grep -oP "(?<=<apikey>)[^<]+" /opt/syncthing/config/config.xml | head -1)}
  ST(){ /opt/syncthing/syncthing cli --gui-address=127.0.0.1:18384 --gui-apikey=$ST_KEY "$@"; }
  echo "DEVICE=$(ST show system 2>/dev/null | jq -r .myID)"
  FID=$(ST config folders list 2>/dev/null | head -1)
  echo "FOLDER=$FID"
  ST config folders "$FID" label get 2>/dev/null | sed "s/^/LABEL=/"
' 2>/dev/null)"
INSTANCE_DEVICE_ID="$(printf '%s\n' "$INST" | sed -n 's/^DEVICE=//p' | head -1)"
FOLDER_ID="$(printf '%s\n' "$INST" | sed -n 's/^FOLDER=//p' | head -1)"
FOLDER_LABEL="$(printf '%s\n' "$INST" | sed -n 's/^LABEL=//p' | head -1)"
FOLDER_LABEL="${FOLDER_LABEL:-ComfyUI Workflows}"
[ -n "$INSTANCE_DEVICE_ID" ] || die "could not read instance device id over SSH"
[ -n "$FOLDER_ID" ] || die "instance has no Syncthing folder (provisioned without SYNCTHING_PEER_DEVICE_ID?)"
log "instance device id: $INSTANCE_DEVICE_ID  folder: $FOLDER_ID ($FOLDER_LABEL)"

# ---------- container side: add device + receiveonly folder (idempotent) ----------
if ! st config devices list 2>/dev/null | grep -qF "$INSTANCE_DEVICE_ID"; then
  st config devices add --device-id "$INSTANCE_DEVICE_ID" --name "vastai-$INSTANCE_ID"
  st config devices "$INSTANCE_DEVICE_ID" compression set always 2>/dev/null || true
fi
if ! st config folders list 2>/dev/null | grep -qF "$FOLDER_ID"; then
  st config folders add --id "$FOLDER_ID" --label "$FOLDER_LABEL (container)" \
    --path "$LOCAL_PATH" --type receiveonly
fi
if ! st config folders "$FOLDER_ID" devices list 2>/dev/null | grep -qF "$INSTANCE_DEVICE_ID"; then
  st config folders "$FOLDER_ID" devices add --device-id "$INSTANCE_DEVICE_ID"
fi

# ---------- instance side: authorize this container as a peer + share folder ----------
"${SSH[@]}" "
  ST_KEY=\${OPEN_BUTTON_TOKEN:-\$(grep -oP '(?<=<apikey>)[^<]+' /opt/syncthing/config/config.xml | head -1)}
  ST(){ /opt/syncthing/syncthing cli --gui-address=127.0.0.1:18384 --gui-apikey=\$ST_KEY \"\$@\"; }
  ST config devices list 2>/dev/null | grep -qF '$CONTAINER_DEVICE_ID' || \
    ST config devices add --device-id '$CONTAINER_DEVICE_ID' --name 'devcontainer-$INSTANCE_ID'
  ST config folders '$FOLDER_ID' devices list 2>/dev/null | grep -qF '$CONTAINER_DEVICE_ID' || \
    ST config folders '$FOLDER_ID' devices add --device-id '$CONTAINER_DEVICE_ID'
" 2>/dev/null || log "WARNING: could not auto-authorize container device on the instance; add $CONTAINER_DEVICE_ID there manually"

# ---------- wait for connection ----------
log "waiting for connection (up to 60s)..."
CONNECTED=no
for _ in $(seq 1 30); do
  if st show connections 2>/dev/null | jq -e ".connections[\"$INSTANCE_DEVICE_ID\"].connected == true" >/dev/null 2>&1; then
    CONNECTED=yes; break
  fi
  sleep 2
done

echo
echo "== Result =="
echo "  container device : $CONTAINER_DEVICE_ID"
echo "  instance device  : $INSTANCE_DEVICE_ID"
echo "  folder           : $FOLDER_ID -> $LOCAL_PATH (receiveonly)"
echo "  config dir       : $CFG (persistent across rebuilds)"
echo "  connection       : $CONNECTED"
[ "$CONNECTED" = yes ] && echo "  -> paired. Instance ComfyUI saves now mirror into $LOCAL_PATH" \
  || echo "  -> not yet connected; daemons may still be in discovery/relay handshake (give it a few min)"
exit 0
