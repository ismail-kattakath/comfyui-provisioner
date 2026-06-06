#!/usr/bin/env bash
# scripts/ensure-stack.sh <STACK_REPO>
#
# Idempotently ensure a stack repo is present as a sibling of comfyui-
# provisioner, fetch the latest refs (without auto-pulling), then refresh
# the local workspace + devcontainer compose-siblings fragment.
#
# Input  : STACK_REPO = "owner/repo" or full git URL
# Output : STDOUT prints exactly one line — `STACK_DIR=<absolute path>` —
#          so callers can `STACK_DIR=$(scripts/ensure-stack.sh foo/bar | tail -1
#          | cut -d= -f2)` or `eval "$(scripts/ensure-stack.sh ... | tail -1)"`.
#          Everything else is stderr.
# Exit   : 0 ok | 1 bad usage | 2 clone/fetch failed
#
# All paths derived from this script's own location — no hardcoded usernames
# or absolute paths anywhere.
set -euo pipefail

STACK_REPO="${1:-}"
if [[ -z "$STACK_REPO" ]]; then
  cat >&2 <<'USAGE'
usage: ensure-stack.sh <owner/repo>
       ensure-stack.sh <git-url>

Examples:
  ensure-stack.sh ismail-kattakath/comfyui-stack-iclight-v2v
  ensure-stack.sh git@github.com:owner/comfyui-stack-foo.git
USAGE
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$PROVISIONER_ROOT/.." && pwd)"

# Normalize input → basename + clone URL
case "$STACK_REPO" in
  *://*|git@*)
    STACK_BASENAME="$(basename "${STACK_REPO%.git}")"
    CLONE_URL="$STACK_REPO"
    ;;
  */*)
    STACK_BASENAME="$(basename "$STACK_REPO")"
    CLONE_URL="https://github.com/${STACK_REPO}.git"
    ;;
  *)
    echo "[ensure-stack] invalid STACK_REPO: '$STACK_REPO' — expected owner/repo or git URL" >&2
    exit 1
    ;;
esac

STACK_DIR="$PARENT_DIR/$STACK_BASENAME"

if [[ ! -d "$STACK_DIR/.git" ]]; then
  echo "[ensure-stack] cloning $CLONE_URL -> $STACK_DIR" >&2
  if ! git clone "$CLONE_URL" "$STACK_DIR" >&2; then
    echo "[ensure-stack] clone failed (auth? private repo? wrong slug?)" >&2
    exit 2
  fi
else
  echo "[ensure-stack] $STACK_BASENAME already present; fetching" >&2
  if ! git -C "$STACK_DIR" fetch --quiet --all 2>/dev/null; then
    echo "[ensure-stack] fetch failed (offline or no upstream)" >&2
  fi
  # Report divergence but never auto-pull (could clobber in-flight work)
  AHEAD_BEHIND="$(git -C "$STACK_DIR" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null || true)"
  if [[ -n "$AHEAD_BEHIND" ]]; then
    BEHIND="${AHEAD_BEHIND%%	*}"
    AHEAD="${AHEAD_BEHIND##*	}"
    if [[ "$BEHIND" -gt 0 ]]; then
      echo "[ensure-stack] $STACK_BASENAME is $BEHIND commit(s) behind upstream — run 'git -C $STACK_DIR pull --ff-only' to sync" >&2
    fi
    if [[ "$AHEAD" -gt 0 ]]; then
      echo "[ensure-stack] $STACK_BASENAME has $AHEAD unpushed commit(s)" >&2
    fi
  fi
  if [[ -n "$(git -C "$STACK_DIR" status --porcelain)" ]]; then
    echo "[ensure-stack] $STACK_BASENAME has uncommitted changes" >&2
  fi
fi

# Regenerate workspace + compose siblings (covers any siblings, not just this one)
"$SCRIPT_DIR/refresh-workspace.sh"

echo "STACK_DIR=$STACK_DIR"
