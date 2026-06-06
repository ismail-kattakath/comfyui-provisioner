#!/usr/bin/env bash
# .claude/hooks/syncthing-session-start.sh
#
# SessionStart hook: for each sibling stack under /workspaces that has a
# .syncthing-instance marker, run ensure-syncthing.sh in auto-heal mode in
# the BACKGROUND. Non-blocking — never delays session start. Logs to
# /tmp/syncthing-ensure-<stack>.log. Safe no-op when no marker files exist.
#
# Policy: the Mac host NEVER runs Syncthing; all wiring is container-side.

set -euo pipefail

PROVISIONER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENSURE_SCRIPT="$PROVISIONER_DIR/scripts/ensure-syncthing.sh"
MARKER=".syncthing-instance"

[ -f "$ENSURE_SCRIPT" ] || exit 0   # framework not available

# Find all stacks with a .syncthing-instance marker
FOUND=0
for stack_dir in /workspaces/comfyui-stack-*/; do
  [ -f "$stack_dir/$MARKER" ] || continue
  STACK_NAME="$(basename "$stack_dir")"
  LOG="/tmp/syncthing-ensure-${STACK_NAME}.log"
  # Cap: timeout 120s so a broken instance never hangs the session
  ( timeout 120 bash "$ENSURE_SCRIPT" "$stack_dir" >> "$LOG" 2>&1 ) &
  FOUND=1
done

# Also check cwd stack if it has a marker and isn't already covered
if [ -f "$PWD/$MARKER" ]; then
  CWD_NAME="$(basename "$PWD")"
  LOG="/tmp/syncthing-ensure-${CWD_NAME}.log"
  if [ ! -d "/workspaces/comfyui-stack-${CWD_NAME}" ]; then
    ( timeout 120 bash "$ENSURE_SCRIPT" "$PWD" >> "$LOG" 2>&1 ) &
    FOUND=1
  fi
fi

[ "$FOUND" -eq 0 ] && exit 0   # no markers — silent no-op

exit 0
