#!/usr/bin/env bash
# scripts/sync-status.sh
#
# Detect the Syncthing TOPOLOGY for a stack from inside the devcontainer and
# prescribe the correct action. The key distinction the rest of the tooling
# conflates is whether the stack's comfyui/ dir is a HOST bind-mount or not —
# because that flips the right answer:
#
#   S1  host-backed + live   — host Syncthing mirrors into the bind-mount.
#                              Consume via the mount; drive pairing/health from
#                              the HOST. Do NOT run a container daemon.
#   S2a host-backed + stale  — bind-mount present but data is stale. Host
#                              Syncthing is likely down (Mac asleep/stopped) OR
#                              the instance is simply idle. START host Syncthing;
#                              still do NOT run a container daemon.
#   S2b hostless             — comfyui/ is NOT a host bind-mount (cloud/remote
#                              container; container-internal fs). THIS is when a
#                              container-side Syncthing is correct:
#                              /pair-syncthing-container <instance>.
#
# GUARD: if a host bind-mount is detected AND a container syncthing daemon is
# running against it, that is a conflict — this script flags it loudly.
#
# Read-only. Never starts, stops, or configures anything.
#
# Usage:
#   scripts/sync-status.sh [STACK_DIR | STACK_NAME]
#     STACK_DIR   path to a stack repo (must contain comfyui/)
#     STACK_NAME  bare name resolved under /workspaces (e.g. iclight-v2v ->
#                 /workspaces/comfyui-stack-iclight-v2v)
#     (default: cwd if it has comfyui/)
#   Env: STALE_MIN (minutes; default 30) — freshness threshold for S1 vs S2a.
#
# Exit codes:
#   0  S1   healthy host sync (or paired + host-backed, just idle)
#   2  S2a / S2b — an action is recommended (start host sync, or pair container)
#   1  cannot determine (no comfyui/ found)

set -uo pipefail

STALE_MIN="${STALE_MIN:-30}"
ARG="${1:-}"

# ---------- resolve stack comfyui dir ----------
resolve_dir() {
  local a="$1"
  if [ -z "$a" ]; then
    [ -d "$PWD/comfyui" ] && { printf '%s\n' "$PWD/comfyui"; return; }
    return 1
  fi
  [ -d "$a/comfyui" ]            && { printf '%s\n' "$a/comfyui"; return; }
  [ -d "$a" ] && [ "$(basename "$a")" = comfyui ] && { printf '%s\n' "$a"; return; }
  [ -d "/workspaces/$a/comfyui" ]                      && { printf '%s\n' "/workspaces/$a/comfyui"; return; }
  [ -d "/workspaces/comfyui-stack-$a/comfyui" ]        && { printf '%s\n' "/workspaces/comfyui-stack-$a/comfyui"; return; }
  return 1
}

CDIR="$(resolve_dir "$ARG")" || {
  echo "[FAIL] could not find a stack comfyui/ for '${ARG:-<cwd>}'"
  echo "       pass a stack path or name, e.g.: sync-status.sh iclight-v2v"
  exit 1
}
SDIR="$(dirname "$CDIR")"
echo "Stack: $SDIR"
echo "Dir:   $CDIR"

# ---------- is it a host bind-mount? ----------
# Host-backed filesystems for a VS Code / Docker Desktop devcontainer show up as
# virtiofs/9p/nfs/cifs (the host share). Container-internal storage is overlay/
# tmpfs/ext4-on-volume. We treat the share-type fstypes as "host-backed".
MNT="$(findmnt -T "$CDIR" -no TARGET,FSTYPE,SOURCE 2>/dev/null)"
FSTYPE="$(printf '%s' "$MNT" | awk '{print $2}')"
HOST_BACKED=0
case "$FSTYPE" in
  virtiofs|9p|nfs|nfs4|cifs|smb3) HOST_BACKED=1 ;;
esac
echo "Mount: ${MNT:-<none>}"

# ---------- container syncthing present / running? ----------
ST_INSTALLED=0; command -v syncthing >/dev/null 2>&1 && ST_INSTALLED=1
ST_RUNNING=0;   pgrep -x syncthing >/dev/null 2>&1 && ST_RUNNING=1

# ---------- folder marker + freshness ----------
HAS_MARKER=0; [ -d "$CDIR/.stfolder" ] && HAS_MARKER=1
NEWEST_EPOCH=0
if [ -d "$CDIR" ]; then
  NEWEST_EPOCH="$(find "$CDIR" -type f -not -path '*/.stfolder/*' -printf '%T@\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d. -f1)"
  NEWEST_EPOCH="${NEWEST_EPOCH:-0}"
fi
AGE_MIN=-1
if [ "$NEWEST_EPOCH" -gt 0 ]; then
  AGE_MIN=$(( ( $(date +%s) - NEWEST_EPOCH ) / 60 ))
fi

echo
echo "== Signals =="
echo "  host-backed bind-mount : $([ $HOST_BACKED = 1 ] && echo yes || echo NO)  (fstype=${FSTYPE:-?})"
echo "  syncthing CLI in container: $([ $ST_INSTALLED = 1 ] && echo yes || echo no)"
echo "  container syncthing daemon: $([ $ST_RUNNING = 1 ] && echo RUNNING || echo not running)"
echo "  .stfolder marker present : $([ $HAS_MARKER = 1 ] && echo yes || echo no)"
echo "  newest synced file age   : $([ $AGE_MIN -ge 0 ] && echo "${AGE_MIN}m" || echo "n/a (empty)")"

echo
echo "== Verdict =="
RC=0

# GUARD: container daemon against a host bind-mount = conflict
if [ "$HOST_BACKED" = 1 ] && [ "$ST_RUNNING" = 1 ]; then
  echo "  [CONFLICT] A container Syncthing daemon is RUNNING against a host bind-mount."
  echo "             Two daemons managing the same dir corrupt the .stfolder/index."
  echo "             -> Stop the container daemon (pkill syncthing). Sync belongs to the host here."
  RC=2
fi

if [ "$HOST_BACKED" = 1 ]; then
  if [ "$HAS_MARKER" = 0 ]; then
    echo "  S?  host bind-mount present but NOT paired (no .stfolder)."
    echo "      -> Pair from the HOST: /pair-syncthing <instance>   (NOT a container daemon)"
    RC=2
  elif [ "$AGE_MIN" -ge 0 ] && [ "$AGE_MIN" -le "$STALE_MIN" ]; then
    echo "  S1  host-backed + fresh (${AGE_MIN}m). Host Syncthing is active."
    echo "      -> Consume files via the mount. Drive pairing/health from the HOST."
    echo "         Do NOT run a container Syncthing daemon."
  else
    echo "  S2a host-backed + STALE (${AGE_MIN}m > ${STALE_MIN}m threshold)."
    echo "      Host Syncthing may be down (Mac asleep/stopped) — or the instance is just idle."
    echo "      -> If you expect live sync: START host Syncthing (brew services start syncthing /"
    echo "         open Syncthing.app), or re-run /pair-syncthing <instance> from the HOST."
    echo "         Do NOT start a container daemon against this bind-mount."
    RC=2
  fi
else
  echo "  S2b HOSTLESS — comfyui/ is NOT a host bind-mount (fstype=${FSTYPE:-?})."
  echo "      This is the case where a container-side Syncthing is correct."
  if [ "$ST_INSTALLED" = 0 ]; then
    echo "      -> syncthing not installed: rebuild the devcontainer (install-syncthing postCreate)"
    echo "         or: sudo apt-get install -y syncthing"
  fi
  echo "      -> Pair the container as the sync endpoint: /pair-syncthing-container <instance>"
  RC=2
fi

exit "$RC"
