# Stack authoring guide

This guide walks you through creating a new ComfyUI stack repo that meets the quality bar expected by `scripts/preflight-stack.sh` and `scripts/stack-lock.sh`.

See also: [Preflight reference](PREFLIGHT.md) | [README](../README.md#stack-readiness-preflight)

---

## What a stack repo is

The provisioner framework (`comfyui-provisioner`) is generic. A **stack repo** is your specific configuration: which custom nodes, which models, which workflows. The two repos are cloned separately at runtime; the framework never references your stack by name.

```
my-comfyui-stack/
├── provisioner-config.sh     # the 5-array contract (required)
├── comfyui/                  # workflow JSONs (required)
│   ├── my-workflow.json
│   └── comfy.settings.json   # optional ComfyUI settings
└── README.md
```

---

## The 5-array contract

`provisioner-config.sh` must declare five bash arrays. The provisioner sources this file, so it runs in the same shell — keep it side-effect-free (no curl, no apt, no writes). All secrets must come from environment variables; never inline a token.

### `NODE_MAP` — custom nodes

Each entry is a `|`-delimited string: `git-url|commit-sha|folder|extra-pip`

| Field | Required | Description |
|---|---|---|
| `git-url` | yes | HTTPS URL of the git repo. `github.com` URLs are always cloned with `$GITHUB_TOKEN`. |
| `commit-sha` | recommended | Full 40- or 64-hex commit SHA. Empty = floating HEAD (purity WARN). |
| `folder` | yes | Destination folder name under `ComfyUI/custom_nodes/`. Must be unique across all entries. |
| `extra-pip` | optional | Additional pip packages to install after the node's own `requirements.txt`. Space-separated. |

```bash
NODE_MAP=(
  "https://github.com/Comfy-Org/ComfyUI_frontend|a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2|ComfyUI_frontend|"
  "https://github.com/Lightricks/ComfyUI-LTXVideo|deadbeefdeadbeefdeadbeefdeadbeefdeadbeef|ComfyUI-LTXVideo|imageio[ffmpeg]"
)
```

**Purity rule:** every entry should have a full commit SHA. Run `stack-lock.sh --pin-nodes --write` to auto-fill empty pins from the current remote HEAD. Under `--strict` preflight, an empty or non-SHA pin is a hard failure.

### `ALIAS_MAP` — legacy folder renames

Each entry is `Legacy:canonical` — if a custom_nodes folder exists with the old name, the provisioner renames it to the new name before cloning.

```bash
ALIAS_MAP=(
  "ComfyUI_LTX:ComfyUI-LTXVideo"
  "comfyui-ltxvideo:ComfyUI-LTXVideo"
)
```

ALIAS_MAP targets are validated at preflight T1: every target must match a `NODE_MAP` folder name (case-insensitive). An alias pointing to a non-existent folder is a T1 failure.

### `MODEL_MAP` — HuggingFace and public URL models

Each entry is `subdir/filename|url|sha256`

| Field | Required | Description |
|---|---|---|
| `subdir/filename` | yes | Relative path under `ComfyUI/models/`. The subdirectory is created automatically. |
| `url` | yes | Direct download URL. HuggingFace URLs are always fetched with `$HF_TOKEN`. |
| `sha256` | recommended | 64-hex SHA-256 of the file. Verified on download. Run `stack-lock.sh --write` to auto-fill from HF `X-Linked-Etag`. |

```bash
MODEL_MAP=(
  "checkpoints/my-model.safetensors|https://huggingface.co/owner/repo/resolve/abc123def456.../my-model.safetensors|abcdef..."
  "loras/my-lora.safetensors|https://huggingface.co/owner/repo/resolve/main/my-lora.safetensors|"
)
```

**Purity rules:**
- Use a commit revision (`/resolve/<sha>/`) rather than `/resolve/main/`. Run `stack-lock.sh` to get the sha256 from `X-Linked-Etag`, then update the URL manually to pin the revision. (Automatic URL rewriting is planned but not yet implemented — see [known limitation](PREFLIGHT.md#known-limitation-hf-floating-refs).)
- Fill the sha256 field. If left empty, preflight can obtain it from HF's `X-Linked-Etag` but it is not recorded. Run `stack-lock.sh --write` to persist it.

### `MODEL_MAP_CIVITAI` — Civitai models

Each entry is `subdir/filename|url|sha256`

| Field | Required | Description |
|---|---|---|
| `subdir/filename` | yes | Relative path under `ComfyUI/models/`. |
| `url` | yes | Versioned Civitai API URL: `https://civitai.com/api/download/models/<id>` where `<id>` is the specific version ID. |
| `sha256` | **required** | 64-hex SHA-256. Civitai shows this on the model version page. Preflight T1 hard-fails if absent. |

```bash
MODEL_MAP_CIVITAI=(
  "loras/my-civitai-lora.safetensors|https://civitai.com/api/download/models/123456|abcdef0123456789..."
)
```

**Important:** Civitai's R2 presigned URLs reject HEAD requests with 403. Preflight uses a 1-byte authenticated range GET (`-r 0-0`) instead. Always use a versioned `/api/download/models/<id>` URL — never a floating `?type=Model` URL. Non-versioned URLs are a purity WARN (FAIL under `--strict`).

### `WORKFLOW_MAP` — workflows to stage

Each entry is `filename|optional-fallback-url`

| Field | Required | Description |
|---|---|---|
| `filename` | yes | JSON filename relative to the stack's `comfyui/` directory. |
| `optional-fallback-url` | no | HuggingFace URL to fetch the workflow from if the local file is missing. Useful when the framework is used standalone without the stack repo's `comfyui/`. |

```bash
WORKFLOW_MAP=(
  "my-workflow.json|"
  "backup-workflow.json|https://huggingface.co/owner/repo/resolve/main/backup-workflow.json"
)
```

Preflight T1 checks that every `filename` exists under `comfyui/`. A missing file is a hard T1 failure.

### `MANUAL_MODELS` — manually placed assets (optional)

An optional sixth array for model files that must be placed by hand (e.g. purchased assets, private weights, or models that have no stable download URL).

```bash
MANUAL_MODELS=(
  "loras/next-scene_lora.safetensors"
  "checkpoints/hardcut.safetensors"
)
```

Entries in `MANUAL_MODELS` are treated by preflight T4 as "known" — workflow references to those filenames will not produce a T4 warning. They are not downloaded by the provisioner.

---

## Recommended authoring loop

```
1. Write provisioner-config.sh + comfyui/ workflows
2. scripts/preflight-stack.sh /path/to/stack          # must exit 0 or 2
3. scripts/stack-lock.sh --write --pin-nodes /path/to/stack
4. scripts/preflight-stack.sh --strict /path/to/stack  # target: exit 0
5. Commit provisioner-config.sh (now with sha256 + pins recorded)
```

The loop is designed to be fast: steps 2 and 4 only probe URLs (never download bytes), so they run in seconds on a laptop.

---

## Zero-trust and pinning expectations

### Zero-trust: no URL is public

Every host has a required token. A missing token is a hard NOT-READY failure:

| Host | Token |
|---|---|
| `github.com` | `$GITHUB_TOKEN` |
| `huggingface.co` | `$HF_TOKEN` |
| `civitai.com` | `$CIVITAI_API_KEY` |

Set these in your environment (or `.env` file — never commit it). The framework injects them at provisioning time via the provider's `onstart.sh`.

### Maximal pinning purity

The goal is a fully reproducible stack: the same `provisioner-config.sh` always produces byte-for-byte identical results.

| Asset | Purity target |
|---|---|
| Custom nodes | Full 40-hex commit SHA in field 2 of `NODE_MAP` |
| HF models | Commit-pinned `/resolve/<sha>/` URL + recorded sha256 in field 3 of `MODEL_MAP` |
| Civitai models | Versioned `/api/download/models/<version-id>` URL + sha256 in field 3 |

Running `stack-lock.sh --write --pin-nodes` gets you most of the way there. The remaining gap (HF URL revision pinning) requires a manual URL update until the automatic rewrite is implemented.

---

## Common pitfalls

### git-lfs is required for some nodes

Some custom nodes (including `ComfyUI-LTXVideo`) store large binary assets in git-lfs. If `git-lfs` is not installed on the instance, the clone will appear to succeed but the large files will be stub text files, causing the node to fail at load time. Ensure your base image or `onstart.sh` installs `git-lfs` before running the provisioner.

### mediapipe has no arm64 wheel

`mediapipe` does not publish `linux/arm64` wheels on PyPI. Any node that lists it in `requirements.txt` will fail `pip install` on arm64 instances. Either constrain your instances to `amd64`/`x86_64` only, or list `mediapipe` in `extra-pip` with a conditional install.

### comfyui_nvidia_rtx_nodes is CUDA-only

`comfyui_nvidia_rtx_nodes` requires a CUDA-capable GPU and will fail to import (and may abort ComfyUI startup) on CPU-only or AMD instances. Only include it if your stack is constrained to NVIDIA instances.

### Civitai HEAD requests return 403

Do not test Civitai URL reachability with a plain `curl -I`. Civitai's R2 presigned URLs reject HEAD with `403 Forbidden` but correctly return `206 Partial Content` for range GETs. Preflight handles this correctly; if you are writing your own tooling, use `curl -r 0-0` with the `Authorization` header.

### Floating HF refs survive stack-lock

`stack-lock.sh --write` records the sha256 for each model but does **not** rewrite `/resolve/main/` URLs to pinned revision URLs. After locking, preflight `--strict` will still flag floating refs. Fix them manually by updating the URL to use the explicit commit sha obtained from HF's `X-Repo-Commit` response header. Automatic rewriting is planned.

### Inline credentials in provisioner-config.sh

Preflight scans `provisioner-config.sh` for patterns matching embedded tokens (`ghp_*`, `hf_*`, `Bearer <token>`, `user:pass@` URLs). Any match is a hard T1 failure. Always pass secrets via environment variables.

### ALIAS_MAP target not in NODE_MAP

If you rename a folder in `NODE_MAP` without updating `ALIAS_MAP`, preflight T1 will fail with "ALIAS_MAP target '...' matches no NODE_MAP folder". Keep the two arrays in sync.

### T4 warnings for node-managed weights

Some nodes download their own weights at runtime (e.g. the LTX audio vocoder). If your workflow references those filenames, T4 will warn about them. Suppress the warnings by adding the basenames to `PREFLIGHT_ALLOW`:

```bash
PREFLIGHT_ALLOW="wav2lip_gan.pth vocoder.pt" scripts/preflight-stack.sh /path/to/stack
```

Or commit a wrapper script that sets `PREFLIGHT_ALLOW` for your stack.

---

## CI gate

See the [CI gate snippet](../README.md#ci-gate) in the main README for a ready-to-use GitHub Actions step.
