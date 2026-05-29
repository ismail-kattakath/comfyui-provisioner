# RunPod Provider

Provisions ComfyUI on a fresh RunPod GPU pod in ~12–20 minutes.

## 1. Overview — RunPod vs VastAI

| Aspect | RunPod | VastAI |
|---|---|---|
| Boot hook | Container Start Command (Docker CMD override) | `PROVISIONING_SCRIPT` env var picked up by `vastai/comfy` image's boot pipeline |
| Portal / Caddy | None — RunPod proxies ports directly | `instance_portal` + Caddy built into `vastai/comfy` image |
| ComfyUI launch | `pkill + nohup python main.py` — no supervisord | supervisorctl via `vastai/comfy` image |
| Port proxy URL | `https://<pod-id>-8188.proxy.runpod.net` | `https://<instance-id>.vast.ai/port/18188/` |
| Volume mount | Fixed `/workspace` (network volume) | `/workspace/ComfyUI/models` (local volume, machine-bound) |
| SSH | `ssh root@<PUBLIC_IP> -p <TCP_PORT>` or `runpodctl exec ssh <id>` | `vastai ssh-url <id>` (returns direct IP) |
| Persistent user state | Manual: mount volume at `/workspace`, symlink inside ComfyUI | Soft-fallback via PERSIST_USER_STATE / PERSIST_OUTPUTS flags |

Key differences:
- **No portal, no Caddy.** RunPod's HTTP proxy tunnels port 8188 directly. The `Open` button equivalent is the pod's proxy URL.
- **pkill + nohup launch.** There's a small race on the very first boot if the Docker image pre-launches its own ComfyUI before this script runs — the `pkill` handles it.
- **ComfyUI at `/root/ComfyUI`.** The `yanwk/comfyui-boot` image puts ComfyUI in `~/ComfyUI` (root user → `/root/ComfyUI`). The provisioner's `COMFYUI_DIR` auto-detection covers `/workspace/ComfyUI` and `$HOME/comfyui` — if the image uses a different path, set `COMFYUI_DIR` explicitly.

## 2. Docker Image

**Chosen:** `yanwk/comfyui-boot:cu124-slim`
- CUDA 12.4, Python 3.12, ComfyUI + ComfyUI-Manager pre-installed
- 814 K+ pulls, actively maintained (last updated May 2026)
- Minimal starting point — no pre-bundled custom nodes to conflict with stack-specified ones
- ComfyUI installed at `/root/ComfyUI`

**Alternatives (in order of preference):**

| Image | Notes |
|---|---|
| `yanwk/comfyui-boot:cu130-slim-v2` | CUDA 13.0, Python 3.13 — newer but may have dependency gaps with older custom nodes |
| `yanwk/comfyui-boot:cu126-megapak` | All-in-one bundle with many custom nodes pre-installed — useful if your stack uses popular nodes, but heavier image (~25 GB) |
| `mmartial/comfyui:latest` | Alternative community image with different path layout — check `COMFYUI_DIR` |

Do NOT use `comfyanonymous/comfyui` — the official ComfyUI project does not publish Docker images on Docker Hub.

## 3. Prerequisites

```bash
# Install runpodctl
brew install runpod/tap/runpodctl     # macOS

# Authenticate
runpodctl config set apiKey <YOUR_RUNPOD_API_KEY>
# API key: https://www.runpod.io/console/user/settings -> API Keys

# Verify
runpodctl get pod
```

## 4. Quick Start

### Minimal one-liner (replace CAPS placeholders):

```bash
runpodctl create pod \
  --name comfyui-mystack \
  --imageName yanwk/comfyui-boot:cu124-slim \
  --containerDiskInGb 100 \
  --volumeInGb 0 \
  --volumeMountPath /workspace \
  --ports "8188/http,22/tcp" \
  --gpuType "NVIDIA GeForce RTX 4090" \
  --gpuCount 1 \
  --minMemoryInGb 24 \
  --env "PUBLIC_KEY=$(cat ~/.ssh/id_ed25519.pub)" \
  --env "HF_TOKEN=$HF_TOKEN" \
  --env "STACK_REPO=owner/your-stack" \
  --env "GITHUB_TOKEN=$GITHUB_TOKEN" \
  --containerStartCommand 'bash -c "curl -fsSL https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/runpod/onstart.sh | bash"'
```

### Via the launch.sh helper (recommended):

```bash
# Dry-print (review before paying):
HF_TOKEN=$HF_TOKEN \
STACK_REPO=owner/your-stack \
GITHUB_TOKEN=$GITHUB_TOKEN \
bash providers/runpod/launch.sh --gpu-type "NVIDIA GeForce RTX 4090"

# Execute:
bash providers/runpod/launch.sh --gpu-type "NVIDIA GeForce RTX 4090" --go
```

After the pod starts (~30 s), provisioning begins. Track progress:

```bash
# Get pod info (IP, ports, status)
runpodctl get pod

# SSH in (direct — faster, no proxy)
ssh root@<PUBLIC_IP> -p <RUNPOD_TCP_PORT_22>

# Or via the runpodctl proxy
runpodctl exec ssh <pod-id>

# Follow provisioning log
tail -f /workspace/provision.log

# Follow ComfyUI startup
tail -f /workspace/comfyui.log
```

## 5. Persistent Network Volumes

RunPod network volumes mount at `/workspace` (fixed path, unlike VastAI where
volumes mount at a specific sub-path). This means **everything** under
`/workspace` persists: cloned repos, models, workflows, logs.

```bash
# Create a network volume (RunPod web UI or via API)
# https://www.runpod.io/console/user/storage

# Attach it on pod create
runpodctl create pod ... --networkVolumeId <volume-id>
```

With a volume:
- `git clone` on first boot → `git pull` on subsequent boots (provisioner idempotency)
- Model downloads short-circuit on size match (Phase 5 already handles this)
- Workflow edits survive pod destroy

Without a volume (default `--volumeInGb 0`): everything re-downloads on each cold boot.

## 6. SSH Access

```bash
# Get your pod's IP and TCP port for SSH
runpodctl get pod
# Look for: PUBLIC_IP and RUNPOD_TCP_PORT_22 in the env / port mappings

# Direct SSH (recommended — faster, no Cloudflare proxy)
ssh root@<PUBLIC_IP> -p <RUNPOD_TCP_PORT_22>

# Proxied SSH via runpodctl (works even without a TCP port mapping)
runpodctl exec ssh <pod-id>
```

The `PUBLIC_KEY` env var is written to `~/.ssh/authorized_keys` by the RunPod
pod initialization before the Container Start Command runs.

## 7. Accessing ComfyUI

Once provisioning completes and ComfyUI finishes startup:

```
https://<pod-id>-8188.proxy.runpod.net
```

Find your pod ID with `runpodctl get pod`. The URL is also printed at the end of
`/workspace/provision.log`.

## 8. Limitations

- **Cloudflare 100-second timeout.** RunPod's HTTP proxy is Cloudflare-fronted.
  Any HTTP request that takes longer than 100 seconds will receive a Cloudflare
  error (504 or connection close). For long-running workflows (video generation,
  large batch jobs), this means the browser ComfyUI UI may appear to hang while
  the job continues running on the pod. The job itself is unaffected — only the
  browser's connection to the queue/progress endpoint times out. Workaround:
  poll the API endpoint from a client that connects directly over TCP, or
  SSH in and watch `comfyui.log`.

- **Max ~10 HTTP ports.** RunPod exposes up to 10 HTTP proxy ports per pod.
  This is more than enough for `8188/http + 22/tcp`, but worth noting if
  you add more services.

- **No UDP ports.** RunPod does not support UDP port mappings. Syncthing's
  data sync protocol uses UDP when available but gracefully falls back to TCP —
  no action needed.

- **Container Start Command re-runs on every pod start** (including resume from
  suspend). The provisioner is idempotent (clones become pulls, completed
  downloads short-circuit), so re-runs are fast (~10–30 s) on subsequent boots.

## 9. Workflow Sync via Syncthing

Syncthing mirrors workflow JSON edits to your local Mac in real time — the
same mechanism as the VastAI provider.

**Pre-pair at pod create time (recommended):**

```bash
# Find your laptop's Syncthing device ID
syncthing show system status 2>/dev/null | jq -r .myID
# or: open http://127.0.0.1:8384 -> Actions -> Device ID

# Pass it when creating the pod
runpodctl create pod ... --env "SYNCTHING_PEER_DEVICE_ID=<YOUR_DEVICE_ID>"
```

When `SYNCTHING_PEER_DEVICE_ID` is set, `onstart.sh` will:
1. Start the `syncthing` daemon (if present in the image)
2. Add your laptop as a paired device
3. Create a `sendonly` folder share for `/root/ComfyUI/user/default/workflows/`

On your laptop, accept the share:

```bash
/pair-syncthing <pod-id>
```

**Note:** The `yanwk/comfyui-boot` image does not ship Syncthing by default.
Install it via `apt-get install -y syncthing` in a custom Dockerfile or set up
a post-boot apt install step. The Syncthing block in `onstart.sh` gracefully
skips if the binary is not found.

**Manual pairing (if SYNCTHING_PEER_DEVICE_ID was not set at create time):**

```bash
# SSH in and check the pod's Syncthing device ID from provision.log
grep "syncthing instance device ID" /workspace/provision.log

# Then on your laptop:
/pair-syncthing <pod-id>
```

## 10. Troubleshooting

**ComfyUI not loading after provisioning:**
```bash
ssh root@<IP> -p <PORT>
tail -100 /workspace/comfyui.log   # check for Python errors
tail -100 /workspace/provision.log # check provisioner phases
# Restart manually if needed:
pkill -f "main.py.*--port 8188" || true
sleep 2
cd /root/ComfyUI
nohup python main.py --port 8188 --listen 0.0.0.0 --enable-cors-header --enable-manager > /workspace/comfyui.log 2>&1 &
```

**COMFYUI_DIR not found:**
The `yanwk/comfyui-boot` image installs ComfyUI at `/root/ComfyUI`. If the
provisioner's auto-detection misses it, set `COMFYUI_DIR=/root/ComfyUI` via
`--env` on pod create. If you switch to a different image (e.g., one that uses
`/workspace/ComfyUI`), update accordingly.

**Re-run the provisioner (e.g., after pushing fixes to the stack repo):**
```bash
ssh root@<IP> -p <PORT>
bash /workspace/reprovision.sh
```

**Private stack repo fails to clone:**
Verify `GITHUB_TOKEN` is set and has `repo` read scope. The token must have access
to `STACK_REPO`. Test from SSH: `git ls-remote https://$GITHUB_TOKEN@github.com/$STACK_REPO.git`.

**Pod suspends after idle timeout:**
RunPod pauses idle pods after a configurable timeout. On resume, the Container
Start Command re-runs and re-provisions (fast on second run because files are
cached). If using a network volume, nothing is lost.
