# Devcontainer

A provider-agnostic control plane for `comfyui-provisioner`. It ships the CLIs and
tooling used to provision ComfyUI on any supported provider (VastAI, RunPod, local):
`comfy-cli`, `vastai`, `runpodctl`, `gh`, `direnv`, Claude Code.

The devcontainer does **not** install ComfyUI in its lifecycle. ComfyUI is only needed
by the `local` provider, so installation is handled on demand by
[`providers/local/launch.sh`](../providers/local/launch.sh) (install-if-missing via
`comfy-cli`). For `vastai`/`runpod`, ComfyUI is installed on the remote GPU box by that
provider's `onstart.sh`, so nothing local is required.

## Where ComfyUI lives

Inside the container, `COMFY_WORKSPACE=/comfy` (set in `docker-compose.yml`), so
`launch.sh` installs ComfyUI at **`/comfy/ComfyUI`** (comfy-cli nests `ComfyUI/` under
the workspace). `/comfy` is backed by a Docker **named volume** (`comfyui_data`) that
persists across container rebuilds. Your host machine is untouched by default.

## Host-reuse modes

Three modes control whether the container reuses ComfyUI assets from your **host
machine**. The default never touches the host; reuse is always an explicit opt-in
(set an env var **and** add an override file). There is no silent host access.

| Mode | What it mounts | Host risk |
|------|----------------|-----------|
| **isolated** (default) | Nothing from host; `/comfy` is a container volume | None |
| **share-models** | Host `models/` → `/comfy/ComfyUI/models` (RW) | Models dir is written to (downloads); nodes/workflows untouched |
| **full-reuse** | Entire host ComfyUI → `/comfy/ComfyUI` (RW) | **Provisioner mutates your real install** — clones nodes, downloads models, and `ALIAS_MAP` **renames** `custom_nodes/` folders |

**share-models** is the recommended way to reuse host assets: you skip re-downloading
multi-GB models, while custom nodes, workflows, and the venv stay isolated in the
container — so provisioning can't rename or clobber the rest of your host install.

### Enabling a mode

1. Set the host path (in `.env`, your shell, or wherever your devcontainer reads env):
   - share-models: `HOST_MODELS_DIR=/Users/you/comfyui/models`
   - full-reuse:   `HOST_COMFYUI_DIR=/Users/you/comfyui`  (the dir containing `main.py`)
2. Add the matching override file to `dockerComposeFile` in `devcontainer.json`:
   ```jsonc
   // isolated (default):
   "dockerComposeFile": ["docker-compose.yml"],

   // share-models:
   "dockerComposeFile": ["docker-compose.yml", "docker-compose.share-models.yml"],

   // full-reuse:
   "dockerComposeFile": ["docker-compose.yml", "docker-compose.full-reuse.yml"],
   ```
3. Rebuild the container.

Devcontainers do **not** auto-load `docker-compose.override.yml`, so the override file
must be listed explicitly as above. The host path vars are referenced with
`${VAR:?...}`, so Compose fails loudly if you enable a mode without setting its
variable (an empty value would otherwise bind the container root `/`).
