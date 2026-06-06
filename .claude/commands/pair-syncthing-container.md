---
description: >
  Pair a CONTAINER-side Syncthing with a running VastAI instance — for the
  hostless case (S2b: cloud/remote devcontainer, no host Syncthing, no host
  bind-mount). Starts a daemon in the container with a persistent config, pairs
  it with the instance, and creates a receiveonly folder at the stack's comfyui/.
  Refuses on a host bind-mount. Use: /pair-syncthing-container <instance-id> [stack]
argument-hint: <instance-id> [stack-name|path]
allowed-tools: Bash, Read, mcp__memory__*
---

# /pair-syncthing-container

The container-side analogue of `/pair-syncthing` (which is Mac/host-only). Use
**only** in the hostless topology — confirm with `/sync-status` first. For the
normal local-Mac setup, this is the wrong tool and the underlying script will
refuse (host bind-mount detected).

Reaches the instance over the **VS Code-forwarded SSH agent** (no key file
needed — see CLAUDE.md "SSH access from the devcontainer").

## Usage

```
/sync-status iclight-v2v               # confirm you're actually S2b first
/pair-syncthing-container 39718734 iclight-v2v
```

First token of `$ARGUMENTS` = `INSTANCE_ID` (required); second = stack name/path
(optional, defaults to cwd).

## What it does

1. **Resolves** the stack's `comfyui/` dir.
2. **GUARD** — if that dir is a host bind-mount (virtiofs/9p/nfs), it refuses:
   running a second daemon there corrupts the host's shared `.stfolder`/index.
   Override only with `FORCE=1` and only if the host daemon is permanently gone.
3. **Starts** a container Syncthing daemon with a **persistent** config dir
   (`$SYNCTHING_CONFIG_DIR`, default `/comfy/.syncthing` on the `comfyui_data`
   volume) so the device ID survives rebuilds.
4. **Reads** the instance's device ID + folder over SSH.
5. **Wires both sides**: adds the instance device + a receiveonly folder on the
   container, and authorizes the container's device + folder share on the
   instance (the bit the Mac flow gets from `SYNCTHING_PEER_DEVICE_ID` at
   provision time).
6. **Waits** for the connection and reports device IDs, folder path, and state.

## Step 1 — Pre-flight (do this, don't skip)

```bash
ROOT="$(git rev-parse --show-toplevel)"
bash "$ROOT/scripts/sync-status.sh" "<stack>"   # must report S2b
```
If it reports S1/S2a, **stop** — use `/pair-syncthing` on the host instead.

## Step 2 — Pair

```bash
ROOT="$(git rev-parse --show-toplevel)"
bash "$ROOT/scripts/pair-syncthing-container.sh" <INSTANCE_ID> <stack>
```

## Step 3 — Report + remember

Report the device IDs, folder mapping, and connection state. On success, record
to memory under entity `vastai-<INSTANCE_ID>`:
`syncthing=container-paired`, `container_device_id=...`, `folder=<id> -> <path>`.

## Caveats

- **Status: implemented + syntax-validated, not integration-tested** — there is
  no hostless environment in the current local-Mac setup to exercise the full
  daemon-start + dual-side pairing. Treat the first real run as a shakeout; the
  GUARD makes it safe to invoke (it refuses the local case).
- Only the **workflows** folder is wired (matching `/pair-syncthing`). For logs,
  the same pattern extends to the instance's log folder (cf. `/pair-vastai-logs`).
- Stopping: `pkill syncthing` halts the container daemon; the persistent config
  at `/comfy/.syncthing` remains, so re-pairing is fast.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| "comfyui/ is a HOST bind-mount … refusing" | you're in S1/S2a, not S2b | use `/pair-syncthing` on the host; this command is not for you |
| "syncthing not installed" | image predates the `install-syncthing` postCreate | rebuild the devcontainer, or `sudo apt-get install -y syncthing` |
| "could not read instance device id over SSH" | agent has no keys / instance down | `ssh-add -l` on host; `/check-access <id>` to confirm SSH |
| device id changes every rebuild | config dir not persistent | ensure `$SYNCTHING_CONFIG_DIR` is on a persisted volume (default `/comfy/...`) |
