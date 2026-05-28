#!/usr/bin/env bash
# save-workflow.sh — explicit one-command sync of a ComfyUI workflow edit
# back to its source stack repo on GitHub.
#
# This script implements the "standard PR-style" workflow for AI APIs:
# you iterate freely on a workflow in the ComfyUI UI (Cmd+S writes to
# the live `user/default/workflows/` location), then when you're
# satisfied that a version is worth keeping, you run this script to
# commit + push it back to the stack repo's `main` (or a feature
# branch).
#
# This is NOT auto-on-Cmd+S — that approach produces noisy git history
# and risks pushing unfinished experimental states. This helper makes
# the act of "make this state canonical" an intentional, single
# command.
#
# Usage:
#   bash /workspace/save-workflow.sh                       # interactive picker
#   bash /workspace/save-workflow.sh <name.json>           # push to main
#   bash /workspace/save-workflow.sh <name.json> <branch>  # push to a branch
#   bash /workspace/save-workflow.sh --list                # show live workflows
#
# Requires (from /workspace/.provisioner.env, written by onstart.sh):
#   GH_TOKEN     — GitHub PAT with repo write scope
#   STACK_REPO   — owner/repo (for the View link in output)
#   STACK_DIR    — path to the cloned stack repo on the instance
#
# The clone at $STACK_DIR was authed with GH_TOKEN at provisioning
# time, so `git push origin` works without extra setup.

set -euo pipefail

ENV_FILE=/workspace/.provisioner.env
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "This script requires an instance provisioned by ismail-kattakath/comfyui-provisioner." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${STACK_DIR:?STACK_DIR not set in $ENV_FILE}"
: "${STACK_REPO:?STACK_REPO not set in $ENV_FILE}"
: "${GH_TOKEN:?GH_TOKEN not set in $ENV_FILE — required to push}"

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
WORKFLOWS_LIVE="$COMFYUI_DIR/user/default/workflows"
WORKFLOWS_REPO="$STACK_DIR/comfyui"

[ -d "$WORKFLOWS_LIVE" ] || { echo "ERROR: $WORKFLOWS_LIVE does not exist." >&2; exit 1; }
[ -d "$WORKFLOWS_REPO" ] || { echo "ERROR: $WORKFLOWS_REPO does not exist (expected stack repo to have a comfyui/ dir)." >&2; exit 1; }

# --list — show available workflows then exit
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
  echo "Live workflows at $WORKFLOWS_LIVE:"
  find "$WORKFLOWS_LIVE" -maxdepth 1 -name '*.json' -printf '  %f\n' | sort
  exit 0
fi

NAME="${1:-}"
BRANCH="${2:-main}"

# Interactive picker if no name given
if [ -z "$NAME" ]; then
  echo "Live workflows at $WORKFLOWS_LIVE:"
  mapfile -t WORKFLOWS < <(find "$WORKFLOWS_LIVE" -maxdepth 1 -name '*.json' -printf '%f\n' | sort)
  if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
    echo "  (no .json workflows found)"
    exit 1
  fi
  for i in "${!WORKFLOWS[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${WORKFLOWS[$i]}"
  done
  printf 'Pick a workflow [1-%d, or full filename]: ' "${#WORKFLOWS[@]}"
  read -r PICK
  [ -z "$PICK" ] && { echo "aborted"; exit 1; }
  # Allow numeric pick or direct filename
  if [[ "$PICK" =~ ^[0-9]+$ ]]; then
    IDX=$((PICK - 1))
    if [ "$IDX" -ge 0 ] && [ "$IDX" -lt "${#WORKFLOWS[@]}" ]; then
      NAME="${WORKFLOWS[$IDX]}"
    else
      echo "out of range" >&2; exit 1
    fi
  else
    NAME="$PICK"
  fi
fi

[ -f "$WORKFLOWS_LIVE/$NAME" ] || { echo "ERROR: $WORKFLOWS_LIVE/$NAME not found." >&2; exit 1; }

echo "[save] workflow:  $NAME"
echo "[save] target:    $WORKFLOWS_REPO/$NAME"
echo "[save] stack:     $STACK_REPO"
echo "[save] branch:    $BRANCH"
echo

# Copy live → repo
cp "$WORKFLOWS_LIVE/$NAME" "$WORKFLOWS_REPO/$NAME"

cd "$STACK_DIR"

# Set git identity for this commit (env override allowed)
GIT_USER_NAME="${GIT_USER_NAME:-${USER:-comfyui}}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-${USER:-comfyui}@$(hostname)}"

# Ensure we have the requested branch checked out
CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
if [ "$BRANCH" != "$CUR_BRANCH" ]; then
  if git rev-parse --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
    git checkout "$BRANCH"
    echo "[save] checked out existing branch $BRANCH"
  else
    git checkout -b "$BRANCH"
    echo "[save] created new branch $BRANCH from $CUR_BRANCH"
  fi
fi

# Stage + bail if nothing changed
git add "comfyui/$NAME"
if git diff --cached --quiet; then
  echo "[save] no changes vs $BRANCH — nothing to commit."
  exit 0
fi

# Commit
SHORT_NAME="${NAME%.json}"
HOST=$(hostname)
MSG="Update $SHORT_NAME workflow from ComfyUI on $HOST"
git -c "user.email=$GIT_USER_EMAIL" -c "user.name=$GIT_USER_NAME" \
    commit -m "$MSG" | sed 's/^/[save] /'

# Push
echo "[save] pushing to origin/$BRANCH..."
if ! git push origin "$BRANCH" 2>&1 | sed 's/^/[save] /'; then
  echo
  echo "[save] PUSH FAILED. Likely cause: upstream changed since last fetch."
  echo "[save] Try resolving with:"
  echo "[save]   cd $STACK_DIR && git pull --rebase && git push origin $BRANCH"
  exit 1
fi

SHA=$(git rev-parse --short HEAD)
echo
echo "✓ Pushed."
echo "  commit: $SHA"
echo "  branch: $BRANCH"
echo "  view:   https://github.com/$STACK_REPO/commit/$SHA"
