---
description: >
  Pair a second Syncthing folder for ComfyUI / provisioner / api-wrapper logs
  on a running VastAI instance. Use AFTER /pair-syncthing so the device
  handshake is already established. Logs land in the local stack repo's
  gitignored logs/ directory. Use: /pair-vastai-logs <instance-id>
argument-hint: <instance-id>
allowed-tools: Bash, Read, mcp__memory__*
---

# /pair-vastai-logs

Pair the operator's local Syncthing with a running VastAI instance's
`/var/log/portal/` directory so the ComfyUI stdout/stderr log, the provisioner
log, and the api-wrapper log mirror into the local stack repo's `logs/`
directory in real time. The Mac side is `receiveonly` — instance writes flow
to the Mac, Mac edits are quarantined.

This is the diagnostic counterpart to `/pair-syncthing` (which pairs the
workflows folder). Run **after** `/pair-syncthing` so the device handshake is
already in place — this command only adds the second folder share.

## Why this exists

ComfyUI's in-browser terminal panel shows ~1-2k lines of scrollback. A single
KSampler OOM traceback is ~80 lines. A provisioner failure trace is hundreds
of lines. Real triage needs the full log file, locally, with native Read /
Grep. SSH-tailing the logs every time a render fails wastes turns and hides
context. The mirror solves it once.

## Vast.ai vs Runpod

- **VastAI** — the `vastai/comfy` image already ships Syncthing in the Caddy
  app set with a supervisor entry. `onstart.sh` switches the supervisor user
  to root (so the daemon can read root-owned log files) and pre-pairs the
  operator's device. This command does the local-side accept for the
  **logs** folder specifically. **Supported.**
- **Runpod** — the default Runpod ComfyUI images do NOT ship Syncthing. The
  framework expects the operator to install + supervise it themselves; the
  Runpod onstart.sh in this repo skips the pre-pair logic entirely. This
  command will refuse to run against a Runpod instance for that reason.

## Usage

```
/pair-vastai-logs <instance-id>
```

**Example:**
```
/pair-vastai-logs 39718734
```

---

## Step 0 — Pre-flight

Arguments: `$ARGUMENTS` (first token = `INSTANCE_ID`, required).

1. **Local Syncthing must be running.** Probe `http://127.0.0.1:8384` with
   the API key from `~/Library/Application Support/Syncthing/config.xml`
   (macOS) or `~/.local/state/syncthing/config.xml` (Linux). If down, tell
   the user to start Syncthing.app (or `brew services start syncthing`).

2. **Workflows folder must already be paired.** Probe
   `GET /rest/config/folders/comfyui-workflows` on the local API. If missing,
   tell the user to run `/pair-syncthing <instance-id>` first — the device
   handshake from that step is a prerequisite.

3. **Instance must be reachable.** `vastai ssh-url $INSTANCE_ID` returns the
   `ssh://root@host:port` URL. If empty / non-zero, instance is not running.

4. **Reject Runpod instances.** If `vast-ai` MCP / CLI returns nothing but
   `runpodctl get pods $INSTANCE_ID` succeeds, this is a Runpod instance.
   Tell the user this command is vast.ai-only — the Runpod image doesn't
   ship Syncthing in its default supervisor set.

## Step 1 — Read instance Syncthing state over SSH

Parse `SSH_URL` into `HOST` and `PORT`. In a single SSH session:

```bash
ssh -p $PORT -o StrictHostKeyChecking=no root@$HOST '
  set -e
  ST_KEY=$(grep -oP "(?<=<apikey>)[^<]+" /opt/syncthing/config/config.xml | head -1)
  ST_ADDR=127.0.0.1:18384
  ST_API() { curl -sf -H "X-API-Key: $ST_KEY" "$@"; }
  echo "INSTANCE_DEVICE_ID=$(ST_API http://$ST_ADDR/rest/system/status | jq -r .myID)"

  # Get the Mac device ID that /pair-syncthing already added
  MAC_DEV_ID=$(ST_API http://$ST_ADDR/rest/config/folders/comfyui-workflows \
    | jq -r ".devices[].deviceID" | grep -vF $(ST_API http://$ST_ADDR/rest/system/status | jq -r .myID))
  echo "MAC_DEVICE_ID=$MAC_DEV_ID"
'
```

If `MAC_DEVICE_ID` is empty: the workflows pair was never completed. Bail
and tell the user to run `/pair-syncthing` first.

## Step 2 — Create the logs folder on the instance (sendonly)

Three things in one SSH session:

1. Write a `.stignore` to `/var/log/portal/.stignore` so we only sync
   the four log files we actually want (ComfyUI, provisioner, api-wrapper,
   their .old rotations). Everything else (caddy, jupyter, cron,
   syncthing-self) stays out.
2. PUT a folder config via `/rest/config/folders/comfyui-logs` targeting
   `/var/log/portal` as `sendonly`, with `rescanIntervalS: 30` and
   `fsWatcherEnabled: true` (logs are append-only — fsnotify catches changes
   faster than the default 60s scan).
3. Share with `$MAC_DEVICE_ID`.

```bash
ssh -p $PORT -o StrictHostKeyChecking=no root@$HOST "bash -s" <<EOF
ST_KEY=\$(grep -oP "(?<=<apikey>)[^<]+" /opt/syncthing/config/config.xml | head -1)
ST_API() { curl -sf -H "X-API-Key: \$ST_KEY" "\$@"; }

cat > /var/log/portal/.stignore <<'STIG'
!comfyui.log
!comfyui.log.old
!provisioning.log
!provisioning.log.old
!api-wrapper.log
!api-wrapper.log.old
*
STIG

NEW_FOLDER='{"id":"comfyui-logs","label":"ComfyUI Logs","path":"/var/log/portal","type":"sendonly","rescanIntervalS":30,"fsWatcherEnabled":true,"ignorePerms":true,"devices":[{"deviceID":"'"$MAC_DEVICE_ID"'"}]}'
ST_API -X PUT -H "Content-Type: application/json" -d "\$NEW_FOLDER" \
  "http://127.0.0.1:18384/rest/config/folders/comfyui-logs"
EOF
```

## Step 3 — Derive local stack repo path

```bash
source /workspace/.provisioner.env  # already read in Step 1; STACK_REPO comes from there
LOCAL_REPO=/Users/aloshy/aloshy-ai/$(basename $STACK_REPO)
LOCAL_LOGS=$LOCAL_REPO/logs
mkdir -p "$LOCAL_LOGS"
```

If `$LOCAL_REPO` doesn't exist: tell the user to clone the stack repo first.

## Step 4 — Add matching receiveonly folder on the Mac

PUT to the local Syncthing API:

```bash
LOCAL_KEY=$(grep -oP '(?<=<apikey>)[^<]+' "$HOME/Library/Application Support/Syncthing/config.xml")
NEW='{
  "id": "comfyui-logs",
  "label": "ComfyUI Logs (vastai-'"$INSTANCE_ID"')",
  "path": "'"$LOCAL_LOGS"'",
  "type": "receiveonly",
  "rescanIntervalS": 30,
  "fsWatcherEnabled": true,
  "ignorePerms": true,
  "devices": [{"deviceID":"'"$INSTANCE_DEVICE_ID"'"}]
}'
curl -sf -X PUT -H "X-API-Key: $LOCAL_KEY" -H "Content-Type: application/json" \
  -d "$NEW" "http://127.0.0.1:8384/rest/config/folders/comfyui-logs"
```

The device-add step from `/pair-syncthing` is already in place, so no new
device needs to be added on either side.

## Step 5 — Ensure logs/ is in the stack repo's .gitignore

```bash
if ! grep -q '^logs/$' "$LOCAL_REPO/.gitignore" 2>/dev/null; then
  printf "\n# Mirrored from vast.ai instance via Syncthing\nlogs/\n" >> "$LOCAL_REPO/.gitignore"
fi
```

Commit this on `main` directly if it changed the file (don't open a PR for a
one-line gitignore tweak).

## Step 6 — Wait for first scan + first file (up to ~60s)

```bash
for i in $(seq 1 30); do
  if [ "$(ls $LOCAL_LOGS/*.log 2>/dev/null | wc -l)" -ge 2 ]; then
    break
  fi
  sleep 2
done
```

If still empty after 60s: report as a warning. Common cause is the instance
daemon still running as `user=user` (it can't read root-owned log files).
The `onstart.sh` flip to root only happens on a fresh provision; if the
operator paired an instance that booted without `SYNCTHING_PEER_DEVICE_ID`,
they need to run this manually (and `/pair-vastai-logs` Step 2 can include
it as a fallback for older instances):

```bash
ssh root@$HOST 'sed -i "s|^user=user$|user=root|" /etc/supervisor/conf.d/syncthing.conf && supervisorctl update syncthing'
```

## Step 7 — Report

```
✅ Logs paired with vastai-<INSTANCE_ID>
   Folder: comfyui-logs -> <LOCAL_LOGS>
   Watching: comfyui.log, provisioning.log, api-wrapper.log (+ .old)
   Connection: <direct|relay> via <address>
   Files mirrored: <N>

Daily flow:
  • Logs auto-mirror as ComfyUI runs — no SSH needed for diagnostics.
  • Use Read / Grep on <LOCAL_LOGS>/comfyui.log to inspect failures.
  • Never commit logs/ — it's gitignored.

Tail the live log locally:
  tail -f <LOCAL_LOGS>/comfyui.log
```

## Memory

After successful pair, add to the same `vastai-<INSTANCE_ID>` entity created
by `/pair-syncthing`:

```
add_observations: [{ entityName: f"vastai-{INSTANCE_ID}",
  observations: [
    f"syncthing_logs=paired",
    f"syncthing_logs_folder=comfyui-logs -> {LOCAL_LOGS}",
    f"logs_paired_at={date}"
  ] }]
```

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `comfyui-workflows` folder not found locally | `/pair-syncthing` was never run | run `/pair-syncthing <id>` first |
| Folder created but no files arrive | instance daemon still as `user=user` | run Step 6's `supervisorctl` flip |
| Files arrive but are 0 bytes / stale | log permissions changed mid-run | `ls -la /var/log/portal/` on instance, ensure root-readable |
| `ignorePerms: true` warnings in Syncthing GUI | macOS file mode mismatch from Linux source | benign, ignore |
| `.stignore` not honored | older Syncthing on instance (<1.20) | inspect `cat /var/log/portal/.stignore` on instance |

## Notes

- The instance's logs folder is `sendonly`. Local edits will be silently
  ignored — they stay quarantined as "Locally Changed Items" in the Syncthing
  GUI and are never pushed back.
- `comfyui.log` rotates on every ComfyUI restart — the old content moves to
  `comfyui.log.old` and a fresh `comfyui.log` starts. Both files are tracked.
- `provisioning.log` is append-only across reprovisions. Searching for a
  failed model download across boot cycles is straightforward.
- This command is **idempotent**. Re-running it against an already-paired
  instance is a no-op (PUT to `/rest/config/folders/comfyui-logs` replaces
  the existing config with identical content).

## Composes with

- `/pair-syncthing <id>` — workflow folder pair. Must run first.
- `/deploy-stack` — fresh deploys with `SYNCTHING_PEER_DEVICE_ID` and
  `COMFYUI_LOG_LEVEL` set in env pre-create the instance-side configs so
  this command becomes a near-instant local-accept.
