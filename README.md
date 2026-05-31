# comfyui-provisioner

Generic, idempotent ComfyUI provisioner for cloud GPU rentals (VastAI, RunPod) and local dev. Bring your own `NODE_MAP` / `MODEL_MAP` / workflows.

This repo is **self-contained at runtime** — provider bootstraps (`providers/*/onstart.sh`) clone this framework directly. You may also vendor it into your stack repo as a git submodule for local-dev convenience, but doing so is **not required** and explicitly **not used at runtime** on cloud instances.

## Repo layout

```
comfyui-provisioner/
├── scripts/
│   └── provision-comfyui.sh   # the generic 7-phase provisioner
├── providers/
│   ├── vastai/                # VastAI --onstart-cmd bootstrap + template
│   ├── runpod/                # RunPod pod bootstrap + template
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
| 4 | Stage workflow JSONs from `WORKFLOW_MAP` (repo source → optional HF fallback); `FORCE_RESTAGE=1` overwrites existing destination JSONs instead of preserving them | `SKIP_WORKFLOW=1` |
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
  --env "-e HF_TOKEN=... -e CIVITAI_API_KEY=... -e GITHUB_TOKEN=... -e STACK_REPO=you/your-stack" \
  --onstart-cmd 'bash <(curl -fsSL https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/vastai/onstart.sh)'

# After ~12-15 min, ComfyUI is at http://<vast-ip>:18188
```

See `providers/vastai/README.md` for full details.

## Required env vars (at provisioner runtime)

| Var | When required | Purpose |
|---|---|---|
| `HF_TOKEN` | always | HuggingFace downloads (gated + Bearer auth) |
| `STACK_REPO` | provider bootstraps | `owner/repo` of your stack (cloned by onstart) |
| `GITHUB_TOKEN` | if `STACK_REPO` is private | GitHub PAT with `repo` read scope |
| `CIVITAI_API_KEY` | Phase 5 if `MODEL_MAP_CIVITAI` is non-empty | Civitai downloads |
| `PROVISIONER_CONFIG` | manual runs | Path to `provisioner-config.sh` (provider bootstraps set this automatically) |
| `WORKFLOWS_SRC_DIR` | manual runs | Path to dir containing workflow JSONs (provider bootstraps set this too) |
| `COMFYUI_DIR` | if auto-detect fails | Override ComfyUI install path |
| `COMFY_PIP` | if auto-detect fails | Override pip binary path |

## Providers

- **VastAI** (`providers/vastai/`) — fully implemented. Self-contained onstart: clones this repo + your stack repo independently.
- **RunPod** (`providers/runpod/`) — fully implemented. Same provisioner works; needs the pod-startup wrapper. PRs welcome.
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

## Stack readiness (preflight)

Before you rent a GPU, run `scripts/preflight-stack.sh` against your stack repo. It is
**read-only and GPU-free** — it probes URLs (HEAD or 1-byte range GET) but never downloads
model bytes. A bad stack caught on a laptop saves an hour of spot-GPU burn that never reaches
inference.

```bash
# Basic check (exits 0=READY, 1=NOT-READY, 2=NEEDS-FETCH)
scripts/preflight-stack.sh /path/to/my-stack

# Strict mode: purity WARNs become hard FAILs (use after locking)
scripts/preflight-stack.sh --strict /path/to/my-stack

# Machine-readable output for CI
scripts/preflight-stack.sh --json /path/to/my-stack

# Network-verify every NODE_MAP commit pin is still fetchable
scripts/preflight-stack.sh --verify-pins /path/to/my-stack
```

### Readiness tier ladder

| Tier | Name | What it checks | Abort on fail? |
|---|---|---|---|
| **T0** | Structural | `provisioner-config.sh` exists and sources cleanly; all 5 arrays declared; `comfyui/` present | Yes |
| Auth | Zero-trust | Required tokens present; no inline credentials in config | No (continues) |
| **T1** | Referential | `WORKFLOW_MAP` files exist in `comfyui/`; `ALIAS_MAP` targets match `NODE_MAP` folders; folder names unique; Civitai sha256 present | No |
| **T2** | Reachability | Every model URL returns 200/206; every node git repo answers `git ls-remote` | No |
| **T3** | Provenance | sha256 recorded or obtainable from HF `X-Linked-Etag`; Civitai URLs are versioned | No |
| **T4** | Coherence (advisory) | Every model the workflow JSON references is covered by a MAP, `MANUAL_MODELS`, or allowlist entry | Advisory only |

T0–T3 are **correctness** gates calibrated against a known-good corpus — all comfyui-stack-* repos pass them in default mode. Purity (full commit pins, recorded sha256, pinned HF revision URLs) is a separate dimension: WARN by default, hard FAIL under `--strict`.

### Exit codes

| Code | Name | Meaning |
|---|---|---|
| **0** | READY | All correctness gates pass; nothing blocking |
| **1** | NOT-READY | Dead URL, missing token, hash mismatch, missing required array, or (under `--strict`) a purity violation |
| **2** | NEEDS-FETCH | Correctness passes and everything is reachable, but resources are not yet on disk |

### Zero-trust: no URL is public

Every host requires an explicit token. A missing token is NOT-READY (never a silent skip). Config must contain no inline credentials.

| Host | Token |
|---|---|
| `github.com` | `$GITHUB_TOKEN` |
| `huggingface.co` | `$HF_TOKEN` |
| `civitai.com` | `$CIVITAI_API_KEY` |

Note: Civitai's R2 presigned URLs reject HEAD with 403. Preflight uses a 1-byte authenticated range GET instead.

### Maximal pinning purity

The goal is a reproducible stack — the same `provisioner-config.sh` always produces byte-for-byte identical results:

- **Nodes:** full 40-hex commit SHA in `NODE_MAP` field 2.
- **HF models:** commit-pinned `/resolve/<sha>/` URL + recorded sha256 in `MODEL_MAP` field 3.
- **Civitai models:** versioned `/api/download/models/<version-id>` URL + sha256 in `MODEL_MAP_CIVITAI` field 3.

### Locking provenance with `stack-lock.sh`

`scripts/stack-lock.sh` is the companion write tool that backfills sha256 from HuggingFace `X-Linked-Etag` and (optionally) pins empty node commits to remote HEAD:

```bash
# Dry-run (prints proposed changes, touches nothing)
scripts/stack-lock.sh /path/to/my-stack

# Pin empty NODE_MAP commits to current remote HEAD
scripts/stack-lock.sh --pin-nodes /path/to/my-stack

# Apply changes (keeps provisioner-config.sh.bak)
scripts/stack-lock.sh --write --pin-nodes /path/to/my-stack

# Re-check with strict mode after locking
scripts/preflight-stack.sh --strict /path/to/my-stack
```

**Known limitation:** `stack-lock.sh` does not yet rewrite floating HF `/resolve/main/` URLs to pinned revision URLs. After locking, `--strict` will still flag floating HF refs. Fix them manually using the commit sha from HF's `X-Repo-Commit` response header. Automatic rewriting is planned.

### CI gate

```yaml
- name: Preflight stack
  env:
    HF_TOKEN: ${{ secrets.HF_TOKEN }}
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    CIVITAI_API_KEY: ${{ secrets.CIVITAI_API_KEY }}
  run: |
    git clone https://github.com/ismail-kattakath/comfyui-provisioner provisioner
    provisioner/scripts/preflight-stack.sh --strict --json .
    # exit 0 = READY, exit 2 = NEEDS-FETCH (acceptable), exit 1 = NOT-READY (fail)
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || exit 1
```

For detailed documentation see:
- [docs/PREFLIGHT.md](docs/PREFLIGHT.md) — precise tier and flag reference
- [docs/STACK-AUTHORING.md](docs/STACK-AUTHORING.md) — end-to-end stack authoring guide


## License

MIT — see `LICENSE`.
