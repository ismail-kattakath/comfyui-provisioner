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

cd "$STACK_DIR"

# Pre-flight: refuse to proceed on top of an unfinished rebase from a
# previous run. Auto-cleanup is risky (could discard intentional manual
# work), so we surface the situation explicitly and let the user decide.
if [ -d "$STACK_DIR/.git/rebase-merge" ] || [ -d "$STACK_DIR/.git/rebase-apply" ]; then
  echo "[save] WARNING: a previous rebase is unfinished in $STACK_DIR" >&2
  echo "[save] Resolve before continuing:" >&2
  echo "[save]   cd $STACK_DIR && git status   # see what's in progress" >&2
  echo "[save]   git rebase --continue          # if you've fixed conflicts" >&2
  echo "[save]   git rebase --abort             # to discard the half-done rebase" >&2
  echo "[save] If you're sure nothing's salvageable:" >&2
  echo "[save]   rm -rf $STACK_DIR/.git/rebase-merge $STACK_DIR/.git/rebase-apply" >&2
  exit 1
fi

# Persist git identity into THIS repo's config (not just for one command).
# Required because `git pull --rebase` later in this script reads from
# config, not from `-c` overrides — without persisted identity, rebase
# fails with "Committer identity unknown" if the repo's email/name
# aren't set. Env vars take priority for explicit override; otherwise
# we derive a sane default from $USER@$(hostname).
GIT_USER_NAME="${GIT_USER_NAME:-${USER:-comfyui-on-vastai}}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-${USER:-comfyui}@$(hostname)}"
git config user.name  "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"

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

# Fetch + rebase BEFORE committing. The stack repo's `main` often has
# new commits (CI workflow tweaks, README updates) since the instance
# was provisioned — without this rebase, the push at the end would be
# rejected as non-fast-forward and the user would be stuck untangling
# a detached-HEAD recovery. Doing rebase first keeps the happy path
# simple: local clone is current, then we add our commit on top.
#
# Skip when AUTO_REBASE=0 — some users may prefer manual control of
# this step if their setup uses long-lived feature branches.
if [ "${AUTO_REBASE:-1}" = "1" ]; then
  echo "[save] fetching + rebasing on origin/$BRANCH (set AUTO_REBASE=0 to skip)..."
  if ! git fetch origin "$BRANCH" 2>&1 | sed 's/^/[save] /'; then
    echo "[save] fetch failed — proceeding without rebase"
  else
    # Only rebase if origin/$BRANCH exists (it would on first push to a new branch otherwise)
    if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
      if ! git rebase "origin/$BRANCH" 2>&1 | sed 's/^/[save] /'; then
        echo
        echo "[save] REBASE FAILED with conflicts."
        echo "[save] Resolve manually:"
        echo "[save]   cd $STACK_DIR"
        echo "[save]   # edit conflicted files, then:"
        echo "[save]   git add <files>; git rebase --continue"
        echo "[save]   git push origin $BRANCH"
        echo "[save] Or abort the rebase + try again:"
        echo "[save]   git rebase --abort"
        exit 1
      fi
    fi
  fi
fi

# Re-copy the live workflow after rebase (rebase may have changed the
# tree; we want our edits to land on top of the now-current upstream).
cp "$WORKFLOWS_LIVE/$NAME" "$WORKFLOWS_REPO/$NAME"

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
git commit -m "$MSG" | sed 's/^/[save] /'

# Push
echo "[save] pushing to origin/$BRANCH..."
if ! git push origin "$BRANCH" 2>&1 | sed 's/^/[save] /'; then
  echo
  echo "[save] PUSH FAILED after rebase. This is unusual — either someone"
  echo "[save] pushed to $BRANCH between our fetch and push, OR the remote"
  echo "[save] rejected for another reason (branch protection, hooks, etc)."
  echo "[save] Re-run this script; if it persists, investigate manually:"
  echo "[save]   cd $STACK_DIR && git status && git log origin/$BRANCH..HEAD"
  exit 1
fi

SHA=$(git rev-parse --short HEAD)
echo
echo "✓ Pushed."
echo "  commit: $SHA"
echo "  branch: $BRANCH"
echo "  view:   https://github.com/$STACK_REPO/commit/$SHA"
