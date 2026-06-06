---
description: >
  Pair the current Mac's Syncthing with a running VastAI ComfyUI instance.
  Resolves the instance's Syncthing device ID + folder config over SSH, adds
  them to local syncthing, and creates a receiveonly folder share at the
  stack's local comfyui/ directory. Use: /pair-syncthing <instance-id>
argument-hint: <instance-id>
allowed-tools: Bash, Read, mcp__memory__*
---

# /pair-syncthing

Pair the operator's local Syncthing with a running VastAI instance so workflow
edits in the instance's ComfyUI UI mirror into the local stack repo's
`comfyui/` directory in real time. Replaces the deprecated `save-workflow.sh`
git-push helper.

Assumes the instance was provisioned with `SYNCTHING_PEER_DEVICE_ID` set
(`providers/vastai/onstart.sh` has already added the Mac as a known device and
created the sendonly folder share on the instance side). This command only
does the Mac-side half: adds the instance device and creates the matching
receiveonly folder.

## Usage

```
/pair-syncthing <instance-id>
```

**Example:**
```
/pair-syncthing 38194805
```

---

## Step 0 — Pre-flight

Arguments: `$ARGUMENTS` (first token = `INSTANCE_ID`, required).

1. **Local syncthing must be running:**
   ```bash
   pgrep -fl syncthing >/dev/null && curl -sf http://127.0.0.1:8384 >/dev/null
   ```
   If not: tell the user to run `brew services start syncthing` (or open
   Syncthing.app if they have the cask) and retry.

2. **`syncthing` CLI must be on PATH:**
   ```bash
   syncthing --version
   ```
   If not: `brew install syncthing`.

3. **Instance must be reachable:**
   ```bash
   SSH_URL=$(vastai ssh-url $INSTANCE_ID)   # ssh://root@<ip>:<port>
   ```
   If that fails: instance is not running. Suggest `vastai show instance
   $INSTANCE_ID` to check status.

## Step 1 — Read instance Syncthing state over SSH

Parse `SSH_URL` into `HOST` and `PORT`, then in a single SSH session:

```bash
ssh -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$HOST '
  set -e
  ST_KEY=${OPEN_BUTTON_TOKEN:-$(grep -oP "(?<=<apikey>)[^<]+" /opt/syncthing/config/config.xml | head -1)}
  ST_CLI() { /opt/syncthing/syncthing cli --gui-address=127.0.0.1:18384 --gui-apikey=$ST_KEY "$@"; }
  echo "INSTANCE_DEVICE_ID=$(ST_CLI show system status | jq -r .myID)"
  FOLDER_ID=$(ST_CLI config folders list | head -1)
  echo "FOLDER_ID=$FOLDER_ID"
  ST_CLI config folders "$FOLDER_ID" get | jq -r ".label, .path"
  source /workspace/.provisioner.env
  echo "STACK_REPO=$STACK_REPO"
'
```

Parse from output:
- `INSTANCE_DEVICE_ID` — XXXXXXX-XXXXXXX-...-XXXXXXX
- `FOLDER_ID` — e.g. `comfyui-workflows` or a stack-specific id
- `FOLDER_LABEL` — display label
- `INSTANCE_FOLDER_PATH` — `/workspace/ComfyUI/user/default/workflows`
- `STACK_REPO` — `owner/repo-name`

If `FOLDER_ID` is empty: instance was provisioned without
`SYNCTHING_PEER_DEVICE_ID`. Tell the user; they need to either reprovision
with that env var set, or run the manual three-command pair on the instance
side (see CLAUDE.md's Syncthing section).

## Step 2 — Derive local stack repo path

```bash
LOCAL_REPO=/Users/aloshy/aloshy-ai/$(basename $STACK_REPO)
LOCAL_PATH=$LOCAL_REPO/comfyui
```

Verify `$LOCAL_PATH` exists. If not, tell the user to `git clone $STACK_REPO`
under `~/aloshy-ai/` first, then retry.

## Step 3 — Add instance device to local Syncthing (idempotent)

```bash
if ! syncthing cli config devices list | grep -qF "$INSTANCE_DEVICE_ID"; then
  syncthing cli config devices add \
    --device-id "$INSTANCE_DEVICE_ID" --name "vastai-$INSTANCE_ID"
  syncthing cli config devices "$INSTANCE_DEVICE_ID" compression set always
fi
```

## Step 4 — Add matching receiveonly folder on Mac (idempotent)

```bash
if ! syncthing cli config folders list | grep -qF "$FOLDER_ID"; then
  syncthing cli config folders add \
    --id "$FOLDER_ID" --label "$FOLDER_LABEL" \
    --path "$LOCAL_PATH" --type receiveonly
fi

if ! syncthing cli config folders "$FOLDER_ID" devices list | grep -qF "$INSTANCE_DEVICE_ID"; then
  syncthing cli config folders "$FOLDER_ID" devices add --device-id "$INSTANCE_DEVICE_ID"
fi
```

## Step 5 — Wait for connection (up to ~60s)

```bash
for i in $(seq 1 30); do
  if syncthing cli show connections | jq -e ".connections[\"$INSTANCE_DEVICE_ID\"].connected == true" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
```

If still not connected after 60s: report as a warning (the daemons may still
be doing global-discovery handshake; usually resolves within a few minutes).

## Step 6 — Report

Print a concise status:

```
✅ Paired with vastai-<INSTANCE_ID>
   Device ID: <INSTANCE_DEVICE_ID>
   Folder:    <FOLDER_ID> → <LOCAL_PATH>
   Connection: <direct|relay> via <address>
   Sync state: <in-sync | N files pending>

Daily flow:
  • Edit workflows in ComfyUI on the instance → Cmd+S
  • Files appear in <LOCAL_PATH> within ~10s
  • `cd <LOCAL_REPO> && git commit -am "..." && git push` from the Mac

Next step (recommended):
  /pair-vastai-logs <INSTANCE_ID>
    Pairs /var/log/portal/ → <LOCAL_REPO>/logs/ so ComfyUI tracebacks,
    provisioner failures, and api-wrapper errors land locally in real time.
    Lets Claude diagnose render failures without SSH-tailing every turn.
```

## Step 7 — Offer cleanup of stale instance devices

List local devices matching `vastai-*` whose names don't match the
just-paired one. If any exist, offer to remove them:

```bash
syncthing cli config devices <stale-id> delete
```

(This is purely cosmetic; Syncthing won't actually try to connect to a
destroyed instance, but the dangling entry clutters the GUI.)

## Memory

After successful pair, record:

```
add_observations: [{ entityName: f"vastai-{INSTANCE_ID}",
  observations: [
    f"syncthing=paired",
    f"syncthing_device_id={INSTANCE_DEVICE_ID}",
    f"syncthing_folder={FOLDER_ID} -> {LOCAL_PATH}",
    f"paired_at={date}"
  ] }]
```

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `vastai ssh-url` returns empty / non-zero | instance not running | `vastai show instance <id>`, wait for `actual_status=running` |
| SSH "Connection refused" | instance still booting | wait + retry; provisioning logs in `/workspace/provision.log` |
| `FOLDER_ID` empty in step 1 | onstart.sh ran without `SYNCTHING_PEER_DEVICE_ID` | reprovision with that env var, OR manually add Mac device + folder on instance via syncthing CLI |
| Folder add fails "already exists" | leftover from earlier pair with different path | `syncthing cli config folders <id> delete` then re-run |
| Connection never establishes | NAT / firewall on Mac side | check `syncthing cli show connections` for the device; falls back to relay automatically — wait longer |
| `syncthing: command not found` | brew formula not installed | `brew install syncthing` |

## Notes

- The instance daemon listens on `127.0.0.1:18384` (not `8384`) — the Caddy
  reverse proxy maps host `40002` → container `8384` for the GUI, but the
  actual process is on `18384`. Always use `--gui-address=127.0.0.1:18384`
  in the SSH session.
- The API key from `config.xml` and the runtime-injected `$OPEN_BUTTON_TOKEN`
  both work against the instance daemon. The pre-flight prefers
  `$OPEN_BUTTON_TOKEN` (no file read needed) and falls back to `config.xml`.
- On the Mac side, `syncthing cli` auto-discovers the local API key from
  `$HOME/Library/Application Support/Syncthing/config.xml`. No flags needed.
