# VastAI Provider

Provisions ComfyUI on a fresh VastAI rental in ~12-15 minutes.

## Architecture

`onstart.sh` runs at first boot and is fully self-contained — **it does NOT rely on any submodule layout**. It clones two repos independently:

1. **This provisioner framework** (`comfyui-provisioner`, public) → `/workspace/comfyui-provisioner`
2. **Your stack repo** (whatever you set as `STACK_REPO`, may be private) → `/workspace/<basename>` (flat clone, no `--recurse-submodules`)

Then sets `PROVISIONER_CONFIG=<stack>/provisioner-config.sh` + `WORKFLOWS_SRC_DIR=<stack>/comfyui` and runs the provisioner. The stack repo's own submodules (if any) are NOT cloned — they're considered local-dev artifacts, not runtime dependencies.

## One-time setup

Your stack repo (e.g. `ismail-kattakath/genai-workflows`) must contain at its root:

- `provisioner-config.sh` — exports `NODE_MAP`, `ALIAS_MAP`, `MODEL_MAP`, `MODEL_MAP_CIVITAI`, `WORKFLOW_MAP`
- `comfyui/` — directory of workflow JSONs (+ optional `comfy.settings.json`)

That's it. No submodule of `comfyui-provisioner` is needed in the stack repo for cloud use — `onstart.sh` pulls the framework directly.

## Renting a new instance

```bash
# Search for an offer (RTX 4090 example, verified providers, cheapest first)
vastai search offers 'gpu_name=RTX_4090 verified=true rentable=true disk_space>=200' \
  --order dph_total --limit 5

# Create instance (replace OFFER_ID with one from above; tokens from your .env)
vastai create instance <offer-id> \
  --image vastai/comfy:v0.22.0-cuda-12.9-py312 \
  --disk 200 \
  --env "-e HF_TOKEN=$HF_TOKEN -e CIVITAI_API_KEY=$CIVITAI_API_KEY -e GH_TOKEN=$GITHUB_PAT -e STACK_REPO=ismail-kattakath/genai-workflows -p 18188:18188" \
  --onstart-cmd 'bash <(curl -fsSL https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/vastai/onstart.sh)'

# Get the new instance's SSH URL (use the direct IP, not the proxied ssh8.vast.ai address)
vastai ssh-url <new-instance-id>
```

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
