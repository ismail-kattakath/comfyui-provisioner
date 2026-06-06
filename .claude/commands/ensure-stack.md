---
description: >
  Ensure a stack repo is present + synced as a sibling of provisioner, and
  refresh the local multi-root workspace + devcontainer compose-siblings
  fragment. Idempotent. Run before any task that touches a stack locally.
argument-hint: <STACK_REPO>  (owner/repo or git URL)
allowed-tools: Bash
---

# /ensure-stack

The reusable primitive for "I'm about to do something that needs stack X
checked out locally." Clones if missing, fetches if present (no auto-pull),
then regenerates `comfyui-workspace.code-workspace` and
`.devcontainer/docker-compose.siblings.yml` based on all current
`comfyui-stack-*` siblings.

Every command that depends on a local stack clone should call this first
rather than reinventing the clone logic.

## Usage

```
/ensure-stack <STACK_REPO>
```

`STACK_REPO` is either `owner/repo` (e.g. `ismail-kattakath/comfyui-stack-iclight-v2v`)
or a full git URL. Never inferred — always supplied by the caller.

## What it does

1. Parses `$ARGUMENTS` → first token is `STACK_REPO` (required, no default).
2. Runs `scripts/ensure-stack.sh "$STACK_REPO"`.
3. Reads the printed `STACK_DIR=...` line (last line of stdout).
4. Reports back:
   - Whether the stack was cloned fresh or already present
   - Whether it has unpushed commits / is behind upstream / has uncommitted changes
   - The absolute `STACK_DIR` path the user can `cd` into
   - The count of siblings now in the workspace file

## What it does NOT do

- Auto-pull. If the stack is behind upstream the script reports it; the user
  decides when to pull (could clobber in-flight work otherwise).
- Modify any tracked file in provisioner. The workspace file and the compose
  siblings fragment are both gitignored — they describe this machine's
  working set, not the tool.
- Push anything. Read-only against remotes (clone + fetch only).

## Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Clone fails with auth error | private repo, no auth | `gh auth login` or set up SSH; retry |
| `invalid STACK_REPO` | not in `owner/repo` form | supply the full slug or git URL |
| `fetch failed (offline or no upstream)` | network down / detached HEAD | non-fatal; script continues using local state |
| Workspace file shows N-1 siblings after adding one | sibling not named `comfyui-stack-*` | rename to match the glob or accept it won't appear |

## Composes with

- `/pair-syncthing <id>` — pairs workflows folder. Needs stack present → ensure first.
- `/pair-vastai-logs <id>` — pairs logs folder. Same.
- `/watch-comfyui-logs <STACK_REPO>` — tails logs. Same.
- Future `/edit-workflow`, `/groom-stack`, etc.

## Output shape

```
✅ ensure-stack <STACK_REPO>
   STACK_DIR: <absolute path>
   State: <fresh-clone | up-to-date | behind N | ahead M | dirty>
   Workspace: <N> sibling(s) listed in comfyui-workspace.code-workspace
```
