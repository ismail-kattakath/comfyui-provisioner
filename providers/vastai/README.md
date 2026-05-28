# VastAI Provider

Provisions ComfyUI on a fresh VastAI rental in ~12-15 minutes.

## Quickstart — launch via VastAI template (one click)

A registered VastAI template wraps the entire CLI launch into a clickable URL:

- **Template page** (description + readme): https://cloud.vast.ai/template/readme/3eb23421f2ae1318446138ca487ca9cd
- **Rent page** (skip straight to offer selection): https://cloud.vast.ai/?template_id=438945&template_hash=901e57e8eda5ac1af68bd580cdca885f

What you fill in before clicking Rent:

| Env var | Required? | Note |
|---|---|---|
| `HF_TOKEN` | yes | `hf_...` — HuggingFace token |
| `GH_TOKEN` | yes (private stacks) | `ghp_...` — GitHub PAT with `repo` read scope |
| `STACK_REPO` | yes | `owner/repo` of your stack (default = `ismail-kattakath/comfyui-stack-qwen-image-edit-aio`) |
| `CIVITAI_API_KEY` | optional | Required only if your stack has Civitai LoRAs |
| `VOLUME_ID` | optional | Set the id + add `--link-volume <id> --mount-path /workspace/ComfyUI/models` in the volume section. See "Optional: persistent network volume" below. |

The template bakes in all the fiddly bits (port mappings, `PORTAL_CONFIG`, `COMFYUI_ARGS`, `OPEN_BUTTON_PORT`, `onstart_cmd`, image tag), so the CLI errors I used to make with quoting are designed out.

If you'd rather use the CLI directly, the full command is documented further down — both flows produce identical instances.

## Architecture

The framework hooks into vastai/comfy at TWO points:

1. **`--onstart-cmd '/opt/instance-tools/bin/entrypoint.sh'`** — invokes the image's normal boot pipeline (entrypoint.sh → boot_default.sh → sources `/etc/vast_boot.d/*` in order)
2. **`PROVISIONING_SCRIPT=<url-to-our-onstart.sh>`** — the image's declarative provisioner downloads + runs our script as Phase 9, AFTER workspace sync and supervisord launch but BEFORE the `/.provisioning` flag is cleared

`/etc/vast_boot.d/*` order:
- `36-sync-workspace.sh` — copies `/opt/workspace-internal/ComfyUI` → `/workspace/ComfyUI`
- `65-supervisor-launch.sh` — touches `/.provisioning`, starts supervisord with the full container env (this is critical — `VAST_TCP_PORT_*` vars must reach Caddy via supervisord)
- `75-provisioning-manifest.sh` — runs the declarative provisioner, which calls our `PROVISIONING_SCRIPT` as its Phase 9
- `95-supervisor-wait.sh` — removes `/.provisioning`; ComfyUI's supervisor script unblocks and starts `python main.py`

Why NOT `--onstart-cmd 'curl|bash'` directly? It overwrites `/root/onstart.sh`, so the image's vast_boot.d pipeline never runs. Result: no workspace sync (`/workspace/ComfyUI` missing → comfyui.sh fails), no supervisord (no services), no PORTAL_CONFIG-driven Caddy (Open button 404s).

`onstart.sh` itself is fully self-contained — **it does NOT rely on any submodule layout**. It clones two repos independently:

1. **This provisioner framework** (`comfyui-provisioner`, public) → `/workspace/comfyui-provisioner`
2. **Your stack repo** (whatever you set as `STACK_REPO`, may be private) → `/workspace/<basename>` (flat clone, no `--recurse-submodules`)

Then sets `PROVISIONER_CONFIG=<stack>/provisioner-config.sh` + `WORKFLOWS_SRC_DIR=<stack>/comfyui` and runs the seven-phase provisioner. The stack repo's own submodules (if any) are NOT cloned — they're considered local-dev artifacts, not runtime dependencies.

## One-time setup

Your stack repo (whatever you set as `STACK_REPO`) must contain at its root:

- `provisioner-config.sh` — exports `NODE_MAP`, `ALIAS_MAP`, `MODEL_MAP`, `MODEL_MAP_CIVITAI`, `WORKFLOW_MAP`
- `comfyui/` — directory of workflow JSONs (+ optional `comfy.settings.json`)

That's it. No submodule of `comfyui-provisioner` is needed in the stack repo for cloud use — `onstart.sh` pulls the framework directly.

## Optional: persistent network volume (recommended when available)

You can attach a VastAI volume at `/workspace/ComfyUI/models` to persist model downloads + workflow edits + UI settings across instance destroy/recreate. The provisioner soft-fails: when `VOLUME_ID` is set, persistence is wired up; when unset, the framework falls back to instance-disk-only (models re-download on every cold boot).

### The VastAI marketplace co-location reality

Local volumes are bound to a specific `machine_id`. To use one, you need:
1. A rentable GPU offer
2. A co-located volume offer on the **same machine_id** (not just same host_id or country)

In practice, only a small fraction of available GPU machines also offer volumes — often just 1 out of 12+ active RTX 4090 hosts at any moment. Use this helper to find a match:

```bash
# Pick a machine that has BOTH a GPU and a volume offer
python3 <<'PY'
import subprocess, json
g = json.loads(subprocess.check_output(['vastai','search','offers',
  'gpu_name in [RTX_4090,RTX_3090] verified=true rentable=true num_gpus=1 disk_space>=100',
  '--limit','50','--raw']))
v = json.loads(subprocess.check_output(['vastai','search','volumes',
  'disk_space>=200 verified=true','--limit','100','--raw']))
g_machs = {o['machine_id']:o for o in g}
v_machs = {o['machine_id']:o for o in v}
for mid in sorted(set(g_machs) & set(v_machs)):
    gpu, vol = g_machs[mid], v_machs[mid]
    print(f"mach={mid} {gpu.get('gpu_name')} ${gpu.get('dph_total',0):.2f}/hr "
          f"+ vol_offer={vol['id']} ${vol.get('storage_cost',0)*200:.2f}/mo "
          f"({gpu.get('geolocation','?')})")
PY
```

### Creating + using a volume

```bash
# Pick a volume offer that's co-located with your chosen GPU offer (per above).
# Names: alphanumeric + underscore only, max 64 chars.
vastai create volume <volume-offer-id> --size 200 --name workday_test
# -> returns: {"success": true, "volume_name": "V.38186467"}

# Export the numeric id (after "V.")
export VOLUME_ID=38186467

# Inspect
vastai show volumes
```

When your work session is done, delete the volume so it stops billing:

```bash
vastai delete volume $VOLUME_ID
```

Costs vary by host — typical pricing is $0.13–$0.33/GB-month, so 200 GB ≈ $26–66/month while the volume exists.

## Renting a new instance

```bash
# Search for an offer (RTX 4090 example, verified providers, cheapest first).
vastai search offers 'gpu_name=RTX_4090 verified=true rentable=true disk_space>=100' \
  --order dph_total --limit 5

# Create instance. The --link-volume + --mount-path + VOLUME_ID lines are
# OPTIONAL — include them only when you have a co-located volume per the
# section above. PORTAL_CONFIG + COMFYUI_ARGS must always be set explicitly
# (the vastai/comfy web-UI template includes them as defaults; CLI does not).
PORTAL='localhost:1111:11111:/:Instance Portal|localhost:8188:18188:/:ComfyUI|localhost:8288:18288:/docs:API Wrapper|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing'

vastai create instance <offer-id> \
  --image vastai/comfy:v0.22.0-cuda-12.9-py312 \
  --disk 100 \
  --link-volume $VOLUME_ID --mount-path /workspace/ComfyUI/models \
  --env "-p 1111:1111 -p 8080:8080 -p 8188:8188 -p 8288:8288 -p 8384:8384 -p 18188:18188 \
         -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/vastai/onstart.sh \
         -e HF_TOKEN=$HF_TOKEN \
         -e CIVITAI_API_KEY=$CIVITAI_API_KEY \
         -e GH_TOKEN=$GITHUB_PAT \
         -e STACK_REPO=owner/your-stack-repo \
         -e VOLUME_ID=$VOLUME_ID \
         -e PORTAL_CONFIG='$PORTAL' \
         -e COMFYUI_ARGS='--disable-auto-launch --port 18188 --enable-cors-header --enable-manager' \
         -e OPEN_BUTTON_PORT=1111 \
         -e OPEN_BUTTON_TOKEN=1" \
  --onstart-cmd '/opt/instance-tools/bin/entrypoint.sh' \
  --ssh --direct

# Without a volume: drop the --link-volume / --mount-path / -e VOLUME_ID
# lines. The framework will run without persistence — models re-download
# every cold boot.

# Get the new instance's SSH URL (use the direct IP, not the proxied ssh8.vast.ai address)
vastai ssh-url <new-instance-id>
```

### How the volume saves re-downloads

The framework's Phase 5 already short-circuits on existing models:
- **HF / public URL downloads** (`MODEL_MAP`): size match → skip. Set `VERIFY_HASHES=1` to also sha256-check against the HF etag.
- **Civitai downloads** (`MODEL_MAP_CIVITAI`): always sha256-verified against the hash in the stack's config.

So when a stack's Phase 5 sees its models already present on the volume (from a previous instance), every entry resolves to `[ok] <path> (<size> bytes)` in milliseconds instead of re-downloading. First-time downloads go to the volume; subsequent boots see them and skip.

### User-state persistence (Cmd+S edits, outputs, inputs)

Two independent env flags control what gets symlinked from instance disk onto the volume.

| Flag | Default in this provider | What it persists |
|---|---|---|
| `PERSIST_USER_STATE` | **1** | `user/default/workflows/` + `user/default/comfy.settings.json` — your Cmd+S edits and UI prefs |
| `PERSIST_OUTPUTS` | **0** | `ComfyUI/output/` + `ComfyUI/input/` — generated images/videos + uploaded references |

Defaults are tuned for the "iterate on workflow → ship as API" pattern: workflows and settings persist across instance destroys (centrally maintained on the volume), but outputs and inputs are treated as ephemeral test artifacts that auto-wipe on destroy. Download the outputs you want to keep before destroying the instance.

When both flags are 1, the volume layout is:

```
$MODELS/_user/                      (volume-backed)
  ├── workflows/                    ← user/default/workflows symlink target
  ├── comfy.settings.json           ← user/default/comfy.settings.json symlink target
  ├── output/                       ← ComfyUI/output symlink target  (PERSIST_OUTPUTS=1 only)
  └── input/                        ← ComfyUI/input symlink target   (PERSIST_OUTPUTS=1 only)
```

#### Why outputs aren't persisted by default

Generated videos can be hundreds of MB each. Over a few iteration cycles on a workflow, that's tens of GB of test artifacts you probably don't care about. Leaving outputs on instance disk:
- Auto-wipes on `vastai destroy instance` — no disk-pressure cleanup needed
- Keeps the volume focused on the things you _do_ want centrally maintained (workflows + settings + models)
- Lower volume cost — a 100 GB volume is enough for most stacks' models

If you want outputs persisted (e.g., you generate something and want it available on the next instance), set `PERSIST_OUTPUTS=1` on instance create via `--env`.

#### Note on instance-disk fill-up

`ComfyUI/output/` and `/tmp` both live on the container's overlay filesystem (instance disk). Linux does NOT auto-clear `/tmp` on disk pressure — disk-full just causes `ENOSPC` on new writes. For long-lived instances generating lots of outputs, either:
1. Download outputs locally and clear them yourself (`rm /workspace/ComfyUI/output/*.png`)
2. Destroy and recreate the instance (cheapest cleanup)
3. Set `PERSIST_OUTPUTS=1` and let outputs spill to the volume instead

#### Phase 4 behavior change

On every re-provision, if a workflow JSON is already present at the target (i.e. on the volume from a previous boot), Phase 4 logs `[skip] <name>.json — preserving user edits` instead of overwriting. Same for `comfy.settings.json`. To force re-stage the pristine version from the stack repo, set `FORCE_RESTAGE=1`:

```bash
ssh -i ~/.ssh/id_ed25519 -p <port> root@<ip>
source /workspace/.provisioner.env
FORCE_RESTAGE=1 bash $PROVISIONER_DIR/scripts/provision-comfyui.sh
```

#### Workflows accumulate across stacks

If you deploy stack A, save edits, then later deploy stack B on the same volume, you'll see both stacks' workflows in the ComfyUI sidebar. ComfyUI lists every `.json` in `workflows/`; pick whichever you want. This is a feature for multi-workflow work sessions.

The vastai/comfy image's normal boot now drives everything:
1. `/etc/vast_boot.d/36-sync-workspace.sh` copies ComfyUI into `/workspace/ComfyUI`
2. `/etc/vast_boot.d/65-supervisor-launch.sh` starts supervisord and touches `/.provisioning`
3. `/etc/vast_boot.d/75-provisioning-manifest.sh` downloads + runs your `PROVISIONING_SCRIPT`
4. `/etc/vast_boot.d/95-supervisor-wait.sh` removes `/.provisioning` — supervisord starts ComfyUI
5. The "Open" button (Instance Portal on port 1111) becomes reachable

## Required env vars

| Var | Required | Purpose |
|---|---|---|
| `HF_TOKEN` | yes | HuggingFace model downloads (gated + Bearer auth) |
| `STACK_REPO` | yes | `owner/repo` containing `provisioner-config.sh` + `comfyui/` |
| `GH_TOKEN` | if STACK_REPO is private | GitHub PAT with `repo` read scope |
| `VOLUME_ID` | recommended (when available) | VastAI volume id. Paired with `--link-volume $VOLUME_ID --mount-path /workspace/ComfyUI/models`. When set, persistence is enabled; when unset, framework runs without persistence. If set but mount missing, provisioner FATALs (intent mismatch). |
| `CIVITAI_API_KEY` | recommended | Civitai LoRA downloads. Phase 5 warns if unset. |

## Optional env vars

| Var | Default | Purpose |
|---|---|---|
| `STACK_BRANCH` | `main` | Stack repo branch |
| `STACK_DIR` | `/workspace/<basename STACK_REPO>` | Where to clone the stack |
| `PROVISIONER_REPO` | `ismail-kattakath/comfyui-provisioner` | This framework's repo (override to use a fork) |
| `PROVISIONER_BRANCH` | `main` | Framework branch |
| `PROVISIONER_DIR` | `/workspace/comfyui-provisioner` | Where to clone the framework |
| `SKIP_*` | `0` | Skip provisioner phases (see main README) |

## Watching progress

```bash
ssh -i ~/.ssh/id_ed25519 -p <port> root@<ip> 'tail -F /workspace/provision.log'
```

The onstart pipes its full output through `tee` to `/workspace/provision.log`, so you can also pull the log after the fact.

## Re-running provisioning after boot

VastAI doesn't export the boot `--env` vars to SSH sessions, so a naive `bash scripts/provision-comfyui.sh` from a fresh SSH shell aborts with `HF_TOKEN must be set in the environment`. To work around this, `onstart.sh` writes the resolved env (tokens + repo paths) to a 600-permissions file at boot:

```
/workspace/.provisioner.env        # chmod 600, sourceable
/workspace/reprovision.sh          # one-shot wrapper that sources the env above
/root/.bashrc                      # appended with auto-loader for interactive shells
```

Three ways to re-run after the initial boot completes:

```bash
# Easiest: the one-shot wrapper. Pulls latest framework + stack first.
ssh -i ~/.ssh/id_ed25519 -p <port> root@<ip> 'bash /workspace/reprovision.sh'

# Or manually: source the env, then run any provisioner command.
ssh -i ~/.ssh/id_ed25519 -p <port> root@<ip>
source /workspace/.provisioner.env
bash $PROVISIONER_DIR/scripts/provision-comfyui.sh

# Or skip phases — env vars are already set after sourcing.
source /workspace/.provisioner.env
SKIP_SYSTEM=1 SKIP_NODES=1 bash $PROVISIONER_DIR/scripts/provision-comfyui.sh
```

New interactive SSH shells auto-load `/workspace/.provisioner.env` via the appended line in `/root/.bashrc`, so the env vars are available without any explicit `source` step after the first login.

> ⚠️ `/workspace/.provisioner.env` stores the HuggingFace, Civitai, and GitHub tokens in clear text. It's `chmod 600` (root-readable only). Don't `cat` it into a screenshot, paste it into a chat, or copy it off the instance.

## Tearing down (save fees)

```bash
yes | vastai destroy instance <id>
# Also destroy any associated network volume if you created one:
vastai show volumes
vastai destroy volume <volume-id>
```

State is reproducible from the public framework + stack repo — nothing important lives only on the instance.
