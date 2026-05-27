# VastAI Provider

Provisions ComfyUI on a fresh VastAI rental in ~12-15 minutes.

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

## Renting a new instance

```bash
# Search for an offer (RTX 4090 example, verified providers, cheapest first)
vastai search offers 'gpu_name=RTX_4090 verified=true rentable=true disk_space>=200' \
  --order dph_total --limit 5

# Create instance — onstart-cmd invokes entrypoint.sh; PROVISIONING_SCRIPT is read inside.
# IMPORTANT: PORTAL_CONFIG + COMFYUI_ARGS must be set explicitly when creating via CLI
# (the vastai/comfy web-UI template includes them as defaults; CLI does not).
PORTAL='localhost:1111:11111:/:Instance Portal|localhost:8188:18188:/:ComfyUI|localhost:8288:18288:/docs:API Wrapper|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing'

vastai create instance <offer-id> \
  --image vastai/comfy:v0.22.0-cuda-12.9-py312 \
  --disk 200 \
  --env "-p 1111:1111 -p 8080:8080 -p 8188:8188 -p 8288:8288 -p 8384:8384 -p 18188:18188 \
         -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/vastai/onstart.sh \
         -e HF_TOKEN=$HF_TOKEN \
         -e CIVITAI_API_KEY=$CIVITAI_API_KEY \
         -e GH_TOKEN=$GITHUB_PAT \
         -e STACK_REPO=owner/your-stack-repo \
         -e PORTAL_CONFIG='$PORTAL' \
         -e COMFYUI_ARGS='--disable-auto-launch --port 18188 --enable-cors-header --enable-manager' \
         -e OPEN_BUTTON_PORT=1111 \
         -e OPEN_BUTTON_TOKEN=1" \
  --onstart-cmd '/opt/instance-tools/bin/entrypoint.sh' \
  --ssh --direct

# Get the new instance's SSH URL (use the direct IP, not the proxied ssh8.vast.ai address)
vastai ssh-url <new-instance-id>
```

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

## Tearing down (save fees)

```bash
yes | vastai destroy instance <id>
# Also destroy any associated network volume if you created one:
vastai show volumes
vastai destroy volume <volume-id>
```

State is reproducible from the public framework + stack repo — nothing important lives only on the instance.
