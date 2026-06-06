---
description: >
  Check, establish, or troubleshoot container-side Syncthing wiring between this
  devcontainer and a running VastAI instance. Auto-heals on default mode.
  Policy: the Mac host never runs Syncthing — all wiring is container-side.
  Use: /sync-wire [--check|--troubleshoot] [stack-name|path] [instance-id]
argument-hint: "[--check|--troubleshoot] [stack-name|path] [instance-id]"
allowed-tools: Bash, Read
---

# /sync-wire

Idempotent Syncthing wiring between the devcontainer and a VastAI instance.
The Mac host **never** runs Syncthing under the current policy — all wiring is
container-side via `scripts/ensure-syncthing.sh`.

Auto-healed on every session start (via the `syncthing-session-start.sh` hook)
for any stack that has a `.syncthing-instance` marker file. Use this command for
manual check, initial wiring, or deep troubleshooting.

## Usage

```
/sync-wire                              # auto-detect stack (cwd) + instance
/sync-wire iclight-v2v                  # named stack, auto-detect instance
/sync-wire iclight-v2v 39718734         # named stack + explicit instance
/sync-wire --check iclight-v2v          # report only, no changes
/sync-wire --troubleshoot iclight-v2v   # full diagnosis: daemon, devices, folders, connection, conflicts
```

First non-flag token = stack name/path; second = instance ID (optional — resolved
from `.syncthing-instance` marker or auto-detect if omitted).

## What it does (default mode)

1. Resolves the stack dir and instance ID (explicit arg → marker file → auto-detect sole running instance).
2. Ensures the container Syncthing daemon is running (`/comfy/.syncthing`, GUI `127.0.0.1:18384`).
3. Reads the instance's folder list and device ID over SSH.
4. **Reconciles container side** (idempotent): for each instance folder, ensures a matching container folder with the correct id, local path, type=receiveonly, and device share. Removes the `default` junk folder if present. Fixes wrong paths.
5. **Reconciles instance side** (idempotent, via SSH): ensures the container device is added and shared on each folder.
6. Records the resolved instance ID to `<stack>/.syncthing-instance` for next-session auto-heal.
7. Verifies connection and folder health; prints a final verdict line.

## Folder mapping

| Instance folder id suffix | Local subdir | Type |
|---|---|---|
| `*-logs` | `logs/` | receiveonly |
| `*-workflows` | `comfyui/` | receiveonly |
| (unknown suffix) | — | warn + skip (exit 2) |

New folder suffixes are easy to add in `scripts/ensure-syncthing.sh` (`map_folder_suffix`).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Wired & healthy (idempotent no-op when already correct) |
| 2 | Healed (changes applied) or needs attention (e.g. >1 running instance, unknown folder) |
| 1 | Hard failure (can't reach instance, daemon won't start) |

## Run it

```bash
ROOT="$(git rev-parse --show-toplevel)"
bash "$ROOT/scripts/ensure-syncthing.sh" $ARGUMENTS
```

## Act on the verdict

- **VERDICT: wired & healthy** — nothing to do.
- **VERDICT: healed** — changes were applied; connection may take 1–2 min for discovery/relay handshake; re-run to confirm.
- **VERDICT: ambiguous — multiple instances running** — pass the instance ID explicitly: `/sync-wire <stack> <instance-id>`.
- **VERDICT: no vastai target** — no marker file and no/multiple running instances; create an instance first.
- **Hard failure (exit 1)** — check SSH agent (`ssh-add -l` on host); confirm instance is running (`vastai show instances`); try `/check-access <instance-id>`.

## --troubleshoot output

Prints a full diagnosis block:
- Container daemon state + device ID
- Container folder list (id, path, type)
- Instance folder list
- Connection state (connected + address)
- Per-folder sync error counts
- Any `.sync-conflict-*` files in the local dirs

For deep automated repair, use the `syncthing-wirer` background agent.

## Notes

- **Daemon persistence**: config lives at `/comfy/.syncthing` (the `comfyui_data` named volume) — survives container rebuilds. Device ID is stable across rebuilds.
- **Device ID read timing**: device ID is read from the running daemon's REST API, never from `--device-id` flag (which requires a cert that is lazily generated and may not exist before the daemon starts).
- **Instance REST**: uses `127.0.0.1:18384` on the instance — NOT `8384` (Caddy auth proxy).
- **SSH**: resolved via `vastai ssh-url <id>` (retried 3×). Never uses the proxied `ssh8.vast.ai` address.
