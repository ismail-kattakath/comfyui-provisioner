#!/usr/bin/env bash
# providers/runpod/onstart.sh
#
# RunPod pod bootstrap. STUB — fill in once you actually deploy.
# RunPod pods use the same general pattern as VastAI:
#   1. Mount or clone the stack repo to a persistent path
#   2. Set PROVISIONER_CONFIG and WORKFLOWS_SRC_DIR
#   3. Run the provisioner
#
# Wire this into your RunPod pod template's "Container Start Command" or use
# RunPod's UI-defined entrypoint script.

set -euo pipefail
echo "[onstart] RunPod provider not yet implemented. PRs welcome."
echo "[onstart] See providers/vastai/onstart.sh for a reference flow."
exit 1
