---
description: >
  Detect the Syncthing topology for a stack from inside the devcontainer and
  prescribe the correct action — distinguishing host-backed+live (S1),
  host-backed+stale (S2a), and hostless (S2b). Read-only; includes a conflict
  guard. Use: /sync-status [stack-name|path]
argument-hint: "[stack-name|path]   (default: cwd)"
allowed-tools: Bash, Read
---

# /sync-status

Answer "what Syncthing situation am I in, and what should I do about it?" — a
question that has *three* answers with different correct actions, which the
pairing commands otherwise conflate. Read-only: it never starts, stops, or
configures anything. Wraps `scripts/sync-status.sh`.

## Usage

```
/sync-status                 # cwd (if it has comfyui/)
/sync-status iclight-v2v     # resolves /workspaces/comfyui-stack-iclight-v2v
/sync-status /path/to/stack
```

## The three topologies

| Verdict | Condition | What to do |
|---|---|---|
| **S1** host-backed + fresh | comfyui/ is a host bind-mount (virtiofs/9p/nfs), `.stfolder` present, files recent | Host Syncthing is live. Consume via the mount; drive pairing/health from the **host** (`/pair-syncthing`). Do **not** run a container daemon. |
| **S2a** host-backed + stale | bind-mount present but data older than `STALE_MIN` (default 30m) | Host Syncthing likely down (Mac asleep/stopped) — **or** the instance is just idle. Start host Syncthing / re-run `/pair-syncthing` on the host. Still no container daemon. |
| **S2b** hostless | comfyui/ is **not** a host bind-mount (overlay/internal — cloud/remote container) | Container-side Syncthing is correct: `/pair-syncthing-container <instance>`. |

## Step 1 — Run it

```bash
ROOT="$(git rev-parse --show-toplevel)"
bash "$ROOT/scripts/sync-status.sh" "$ARGUMENTS"
```

It prints the signals (mount fstype, container daemon state, `.stfolder`, file
age) and a verdict line. Exit `0` = S1 healthy; `2` = an action is recommended
(S2a/S2b); `1` = couldn't find the stack.

## Step 2 — Act on the verdict

- **S1** → nothing to do. If the user wants live confirmation, check connection
  state on the host: `! syncthing cli show connections`.
- **S2a** → tell the user to wake/start host Syncthing; note the ambiguity
  (stale can just mean an idle instance — confirm via the host before assuming a
  fault). Do **not** offer to run a container daemon.
- **S2b** → offer `/pair-syncthing-container <instance-id>`.
- **[CONFLICT]** (container daemon running against a host bind-mount) → tell the
  user to stop it (`pkill syncthing`); two daemons on one dir corrupt the index.

## Notes

- The host-backed test keys on the mount fstype (virtiofs/9p/nfs/cifs = host
  share; overlay/tmpfs = container-internal). On a Linux Docker host bind mounts
  may report the underlying fs — treat the verdict as advisory there and confirm
  with `findmnt -T <dir>`.
- "Stale" is deliberately conservative: an idle instance (GPU 0%) legitimately
  produces no new files. Freshness proves liveness; staleness only *suggests* a
  problem.
