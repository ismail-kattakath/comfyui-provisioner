#!/usr/bin/env bash
# providers/runpod/launch.sh
#
# Local CLI helper — builds a `runpodctl create pod` command from env vars
# and optional flags. Dry-prints by default so you review before paying.
# Pass --go to execute immediately.
#
# Prerequisites:
#   - runpodctl installed + authenticated (`runpodctl config set apiKey <key>`)
#   - Required env vars set (HF_TOKEN, STACK_REPO) — see .env / .env.example
#   - SSH public key available (default: ~/.ssh/id_ed25519.pub or id_rsa.pub)
#
# Usage:
#   bash providers/runpod/launch.sh [flags]
#
# Flags:
#   --gpu-type "NVIDIA GeForce RTX 4090"   GPU model string (default: RTX 4090)
#   --volume-id ID                          Attach a persistent network volume
#   --region REGION                         Pod datacenter region (default: US)
#   --go                                    Execute (don't just print)
#   --help                                  Show this help
#
# Environment (read from shell or .env):
#   HF_TOKEN          (required) HuggingFace token
#   STACK_REPO        (required) owner/repo e.g. owner/my-comfyui-stack
#   GH_TOKEN          (optional) GitHub PAT for private stacks
#   CIVITAI_API_KEY   (optional) Civitai token
#   STACK_BRANCH      (optional, default: main)
#   SYNCTHING_PEER_DEVICE_ID  (optional) Laptop Syncthing device ID for auto-pair
#
# Image used: yanwk/comfyui-boot:cu124-slim
#   ComfyUI installs to ~/ComfyUI (/root/ComfyUI).
#   The provisioner's COMFYUI_DIR auto-detection will find /root/ComfyUI
#   via the ~/comfyui or /root/ComfyUI path — verify if using a different image.
#
# Provisioner URL (raw GitHub):
PROVISIONER_URL="${PROVISIONER_URL:-https://raw.githubusercontent.com/ismail-kattakath/comfyui-provisioner/main/providers/runpod/onstart.sh}"

set -euo pipefail

# ---------- Defaults ----------
GPU_TYPE="NVIDIA GeForce RTX 4090"
VOLUME_ID=""
REGION="US"
DRY_RUN=1

# ---------- Arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpu-type)  GPU_TYPE="$2"; shift 2 ;;
    --volume-id) VOLUME_ID="$2"; shift 2 ;;
    --region)    REGION="$2"; shift 2 ;;
    --go)        DRY_RUN=0; shift ;;
    --help|-h)
      sed -n '2,30p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ---------- Required env ----------
: "${HF_TOKEN:?HF_TOKEN must be set in the environment}"
: "${STACK_REPO:?STACK_REPO must be set in the environment (format: owner/repo)}"

STACK_BRANCH="${STACK_BRANCH:-main}"

# ---------- SSH public key ----------
SSH_PUB=""
for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  if [ -f "$candidate" ]; then
    SSH_PUB="$(cat "$candidate")"
    break
  fi
done
if [ -z "$SSH_PUB" ]; then
  echo "WARNING: No SSH public key found at ~/.ssh/id_ed25519.pub or id_rsa.pub." >&2
  echo "         Set PUBLIC_KEY manually or generate one with: ssh-keygen -t ed25519" >&2
fi

# ---------- Build env string ----------
ENV_ARGS=(
  "--env" "PUBLIC_KEY=${SSH_PUB}"
  "--env" "HF_TOKEN=${HF_TOKEN}"
  "--env" "STACK_REPO=${STACK_REPO}"
  "--env" "STACK_BRANCH=${STACK_BRANCH}"
)
[ -n "${GH_TOKEN:-}" ]             && ENV_ARGS+=("--env" "GH_TOKEN=${GH_TOKEN}")
[ -n "${CIVITAI_API_KEY:-}" ]      && ENV_ARGS+=("--env" "CIVITAI_API_KEY=${CIVITAI_API_KEY}")
[ -n "${SYNCTHING_PEER_DEVICE_ID:-}" ] && ENV_ARGS+=("--env" "SYNCTHING_PEER_DEVICE_ID=${SYNCTHING_PEER_DEVICE_ID}")

# ---------- Build the command ----------
CMD=(
  runpodctl create pod
  --name "comfyui-$(basename "$STACK_REPO")"
  --imageName "yanwk/comfyui-boot:cu124-slim"
  --containerDiskInGb 100
  --volumeInGb 0
  --volumeMountPath "/workspace"
  --ports "8188/http,22/tcp"
  --gpuType "$GPU_TYPE"
  --gpuCount 1
  --minMemoryInGb 24
)

# Attach persistent volume if requested
if [ -n "$VOLUME_ID" ]; then
  CMD+=("--networkVolumeId" "$VOLUME_ID")
fi

# Region
[ -n "$REGION" ] && CMD+=("--dataCenterName" "$REGION")

# Env vars
CMD+=("${ENV_ARGS[@]}")

# Container start command — bootstraps the provisioner on every pod start
CMD+=(
  "--containerStartCommand"
  "bash -c \"curl -fsSL ${PROVISIONER_URL} | bash\""
)

# ---------- Print or execute ----------
echo ""
echo "# RunPod pod create command"
echo "# Image:  yanwk/comfyui-boot:cu124-slim"
echo "# GPU:    $GPU_TYPE"
echo "# Stack:  $STACK_REPO @ $STACK_BRANCH"
[ -n "$VOLUME_ID" ] && echo "# Volume: $VOLUME_ID"
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "# DRY RUN — add --go to execute. Command:"
  echo ""
  # Pretty-print each arg on its own line for readability
  printf '  %s' "${CMD[0]}"
  for arg in "${CMD[@]:1}"; do
    if [[ "$arg" == --* ]]; then
      printf ' \\\n    %s' "$arg"
    else
      printf ' %q' "$arg"
    fi
  done
  echo ""
  echo ""
  echo "# After pod starts, find your pod ID with: runpodctl get pod"
  echo "# SSH:   ssh root@<PUBLIC_IP> -p <RUNPOD_TCP_PORT_22>"
  echo "#        (or: runpodctl exec ssh <pod-id>)"
  echo "# UI:    https://<pod-id>-8188.proxy.runpod.net"
else
  echo "Executing..."
  "${CMD[@]}"
fi
