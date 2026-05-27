# comfyui-provisioner

Generic, idempotent ComfyUI provisioner for cloud GPU rentals (VastAI, RunPod) and local dev. Bring your own `NODE_MAP` / `MODEL_MAP` / workflows.

This repo is **self-contained at runtime** — provider bootstraps (`providers/*/onstart.sh`) clone this framework directly. You may also vendor it into your stack repo as a git submodule for local-dev convenience, but doing so is **not required** and explicitly **not used at runtime** on cloud instances.

## Repo layout

```
comfyui-provisioner/
├── scripts/
│   ├── provision-comfyui.sh   # the generic 7-phase provisioner
│   └── start-comfy.sh         # local ComfyUI launcher (dev helper)
├── providers/
│   ├── vastai/                # VastAI --onstart-cmd bootstrap + template
│   ├── runpod/                # RunPod pod bootstrap (TODO — stub)
│   └── local/                 # macOS/Linux dev workflow
├── requirements.compiled      # pinned base Python deps (uv-compiled)
├── override.txt               # uv override file
└── README.md                  # this file
```

## How it works

The provisioner is split into seven idempotent phases:

| Phase | What | Skip with |
|---|---|---|
| 0 | Preflight (find `COMFYUI_DIR`, `COMFY_PIP`, mask + check tokens, source `$PROVISIONER_CONFIG`) | — |
| 1 | System update + Manager pip upgrade | `SKIP_SYSTEM=1` |
| 2 | Persist tokens to `/etc/environment`; set ComfyUI launch args | — |
| 3 | Clone + pin custom nodes from `NODE_MAP`; install their pip deps | `SKIP_NODES=1` |
| 4 | Stage workflow JSONs from `WORKFLOW_MAP` (repo source → optional HF fallback) | `SKIP_WORKFLOW=1` |
| 5 | Download models: `MODEL_MAP` (HF) + `MODEL_MAP_CIVITAI` (with sha256 verify) | `SKIP_MODELS=1` |
| 6 | ComfyUI-Manager "update all" pass | `SKIP_UPDATE_ALL=1` |
| 7 | Restart ComfyUI via supervisorctl | `SKIP_RESTART=1` |

Each phase is safe to re-run: clones become pulls, completed downloads are skipped (size + checksum verified), failed/partial downloads resume.

## The config contract

Your stack repo must provide a `provisioner-config.sh` at its root that defines five bash arrays:

```bash
# provisioner-config.sh — in your stack repo
NODE_MAP=(
  "<git-url>|<commit-sha-or-empty>|<folder-name>|<extra-pip-args-or-empty>"
  # ... one line per custom node ...
)

ALIAS_MAP=(
  "LegacyFolderName:canonical-folder-name"
  # ... rename existing dirs to canonical names before clone-check ...
)

MODEL_MAP=(
  "<subdir>/<filename>|<download-url>"
  # ... HuggingFace + other public URLs ...
)

MODEL_MAP_CIVITAI=(
  "<subdir>/<filename>|<civitai-url>|<sha256>"
  # ... needs CIVITAI_API_KEY ...
)

WORKFLOW_MAP=(
  "<workflow-filename.json>|<optional-fallback-url>"
  # ... staged from $WORKFLOWS_SRC_DIR; falls back to URL if file missing ...
)
```

Set `PROVISIONER_CONFIG=/path/to/your/provisioner-config.sh` and `WORKFLOWS_SRC_DIR=/path/to/your/comfyui` before running the provisioner. The provider bootstraps (`providers/*/onstart.sh`) do this automatically — see each provider's README.

## Quick start (VastAI)

```bash
# Rent + provision in one shot — the onstart fetches this repo from main HEAD directly
vastai create instance <offer-id> \
  --image vastai/comfy:v0.22.0-cuda-12.9-py312 \
  --disk 200 \
  --env "-e HF_TOKEN=... -e CIVITAI_API_KEY=... -e GH_TOKEN=... -e STACK_REPO=you/your-stack" \
  --onstart-cmd 'bash <(curl -fsSL https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/vastai/onstart.sh)'

# After ~12-15 min, ComfyUI is at http://<vast-ip>:18188
```

See `providers/vastai/README.md` for full details.

## Required env vars (at provisioner runtime)

| Var | When required | Purpose |
|---|---|---|
| `HF_TOKEN` | always | HuggingFace downloads (gated + Bearer auth) |
| `STACK_REPO` | provider bootstraps | `owner/repo` of your stack (cloned by onstart) |
| `GH_TOKEN` | if `STACK_REPO` is private | GitHub PAT with `repo` read scope |
| `CIVITAI_API_KEY` | Phase 5 if `MODEL_MAP_CIVITAI` is non-empty | Civitai downloads |
| `PROVISIONER_CONFIG` | manual runs | Path to `provisioner-config.sh` (provider bootstraps set this automatically) |
| `WORKFLOWS_SRC_DIR` | manual runs | Path to dir containing workflow JSONs (provider bootstraps set this too) |
| `COMFYUI_DIR` | if auto-detect fails | Override ComfyUI install path |
| `COMFY_PIP` | if auto-detect fails | Override pip binary path |

## Providers

- **VastAI** (`providers/vastai/`) — fully implemented. Self-contained onstart: clones this repo + your stack repo independently.
- **RunPod** (`providers/runpod/`) — stub. Same provisioner works; needs the pod-startup wrapper. PRs welcome.
- **Local** (`providers/local/`) — macOS/Linux dev launcher. Useful for testing workflows against your own machine before renting GPU.

## Why this design?

Most "ComfyUI deploy" repos hardcode a single stack (model picks, node versions). When your stack changes, you fork. This repo separates **framework** from **config**:

- **Framework** (this repo, public, MIT): how to provision a ComfyUI instance idempotently across providers
- **Config** (your stack repo, private if needed): what to provision

Result:
- One generic provisioner. Anyone can reuse it for unrelated ComfyUI projects.
- Your stack stays private/proprietary while the deployment logic is open and improvable.
- Provider-specific quirks live in `providers/*/`. Adding a new cloud means writing one onstart script — no fork.
- **Cloud provisioning works even if your stack repo doesn't vendor this framework as a submodule.** The onstart pulls both repos directly; no submodule traversal at runtime.

## License

MIT — see `LICENSE`.
