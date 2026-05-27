# VastAI Provider

Provisions ComfyUI on a fresh VastAI rental in ~12-15 minutes.

## One-time setup

1. Make sure your stack repo (e.g. `ismail-kattakath/genai-workflows`) contains:
   - `provisioner-config.sh` at the root (exports `NODE_MAP`, `MODEL_MAP`, `MODEL_MAP_CIVITAI`, `ALIAS_MAP`, `WORKFLOW_MAP`)
   - `comfyui/` directory with your workflow JSONs
   - This repo (`comfyui-provisioner`) added as a submodule
2. Generate a GitHub PAT with `repo` scope if your stack repo is private. Save somewhere accessible.

## Renting a new instance

```bash
# Search for an offer (RTX 4090 example)
vastai search offers 'gpu_name=RTX_4090 dlperf>20 disk_space>200' --order dlperf --raw \
  | jq -r '.[0].id'

# Create instance using this provider's template (edit env tokens in template.json first OR pass via --env)
vastai create instance <offer-id> \
  --image vastai/comfy:v0.22.0-cuda-12.9-py312 \
  --disk 200 \
  --env "-e HF_TOKEN=$HF_TOKEN -e CIVITAI_API_KEY=$CIVITAI_API_KEY -e GH_TOKEN=$GH_TOKEN -e STACK_REPO=ismail-kattakath/genai-workflows -p 18188:18188" \
  --onstart-cmd 'bash <(curl -fsSL https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/vastai/onstart.sh)'

# Get the new instance's SSH URL (use the direct IP, not the proxied ssh8.vast.ai address)
vastai ssh-url <new-instance-id>
```

## Bootstrap flow (what happens on first boot)

1. VastAI's supervisor starts; runs your `--onstart-cmd`.
2. The onstart script (`providers/vastai/onstart.sh` in this repo) is curl'd and executed.
3. It clones `STACK_REPO` to `/workspace/$(basename STACK_REPO)` (auth via `GH_TOKEN` if private), with submodules.
4. Sets `PROVISIONER_CONFIG=<stack>/provisioner-config.sh` and `WORKFLOWS_SRC_DIR=<stack>/comfyui`.
5. Runs `<stack>/comfyui-provisioner/scripts/provision-comfyui.sh` — sources the config, runs Phases 0-7.
6. ComfyUI is reachable at `http://<vast-ip>:18188` once Phase 7 completes.

Watch progress with:

```bash
ssh -i ~/.ssh/id_ed25519 -p <port> root@<ip> 'tail -f /workspace/provision.log'
```

## Required env vars

| Var | Required | Purpose |
|---|---|---|
| `HF_TOKEN` | yes | HuggingFace model downloads (gated + Bearer auth) |
| `STACK_REPO` | yes | Your private/public repo with `provisioner-config.sh` + `comfyui/` |
| `GH_TOKEN` | if `STACK_REPO` is private | Read access to clone the stack |
| `CIVITAI_API_KEY` | recommended | Civitai LoRAs/checkpoints. Phase 5 warns if unset. |
| `STACK_BRANCH` | no (default `main`) | Branch to clone |
| `STACK_DIR` | no (default `/workspace/<repo>`) | Override stack checkout location |
| `SKIP_*` | no | Skip provisioner phases (see main README) |

## Tearing down (save fees)

```bash
vastai destroy instance <id>
# Also destroy any associated network volume if you created one:
vastai show volumes
vastai destroy volume <volume-id>
```

State is reproducible from the stack repo + this provisioner — nothing is lost.
