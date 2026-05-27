---
name: runpod-mcp
description: RunPod MCP server for managing serverless endpoints, GPU/CPU pods, templates, network volumes, and container registry auths. Use when the user asks about RunPod endpoints, serverless inference, GPU pods, deploying Docker images on RunPod, scaling workers, or managing RunPod infrastructure.
---

# RunPod MCP Server — 26 Tools Reference

Configured in `.mcp.json` as `"runpod"` (`npx @runpod/mcp-server@latest`). Requires `RUNPOD_API_KEY` in `.env`.

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|-----------|
| **— Serverless Endpoints —** | | |
| List all endpoints | `list-endpoints` | `includeTemplate`, `includeWorkers` |
| Get one endpoint | `get-endpoint` | `endpointId` |
| Create endpoint from template | `create-endpoint` | `templateId`, `name`, `gpuTypeIds[]`, `workersMin`, `workersMax` |
| Update endpoint scaling/timeout | `update-endpoint` | `endpointId`, `workersMin`, `workersMax`, `idleTimeout`, `scalerType`, `scalerValue` |
| Delete endpoint | `delete-endpoint` | `endpointId` |
| **— Pods (persistent GPU instances) —** | | |
| List pods | `list-pods` | `computeType`, `gpuTypeId[]`, `name` |
| Get one pod | `get-pod` | `podId`, `includeMachine`, `includeNetworkVolume` |
| Create pod | `create-pod` | `imageName`, `gpuTypeIds[]`, `gpuCount`, `cloudType`, `containerDiskInGb` |
| Update pod | `update-pod` | `podId`, `imageName`, `env{}`, `ports[]` |
| Start pod | `start-pod` | `podId` |
| Stop pod | `stop-pod` | `podId` |
| Delete pod | `delete-pod` | `podId` |
| **— Templates —** | | |
| List templates | `list-templates` | — |
| Get template | `get-template` | `templateId` |
| Create template | `create-template` | `name`, `imageName`, `isServerless`, `env{}`, `containerDiskInGb` |
| Update template | `update-template` | `templateId`, `imageName`, `env{}` |
| Delete template | `delete-template` | `templateId` |
| **— Network Volumes —** | | |
| List volumes | `list-network-volumes` | — |
| Get volume | `get-network-volume` | `networkVolumeId` |
| Create volume | `create-network-volume` | `name`, `size` (GB), `dataCenterId` |
| Expand volume | `update-network-volume` | `networkVolumeId`, `size` (must be larger) |
| Delete volume | `delete-network-volume` | `networkVolumeId` |
| **— Container Registry Auth —** | | |
| List registry auths | `list-container-registry-auths` | — |
| Get registry auth | `get-container-registry-auth` | `containerRegistryAuthId` |
| Add registry auth | `create-container-registry-auth` | `name`, `username`, `password` |
| Delete registry auth | `delete-container-registry-auth` | `containerRegistryAuthId` |

## Tool Parameters

### Endpoints

```
create-endpoint
  templateId*    — Template to deploy (required)
  name           — Endpoint display name
  computeType    — "GPU" | "CPU"
  gpuTypeIds[]   — e.g. ["NVIDIA H100 NVL", "NVIDIA A100 80GB"]
  gpuCount       — GPUs per worker
  workersMin     — Min always-on workers (0 = scale to zero)
  workersMax     — Max concurrent workers
  dataCenterIds[]— Restrict to specific data centers

update-endpoint
  endpointId*    — (required)
  workersMin / workersMax
  idleTimeout    — Seconds before worker scales down
  scalerType     — "QUEUE_DELAY" | "REQUEST_COUNT"
  scalerValue    — Target queue depth or request count for scaling
```

### Pods

```
create-pod
  imageName*     — Docker image (required)
  name           — Pod name
  gpuTypeIds[]   — e.g. ["NVIDIA RTX 4090"]
  gpuCount       — Number of GPUs (default 1)
  cloudType      — "SECURE" | "COMMUNITY"
  containerDiskInGb — Ephemeral disk size
  volumeInGb     — Persistent volume size
  volumeMountPath— Mount path for volume
  ports[]        — e.g. ["8888/http", "22/tcp"]
  env{}          — {"KEY": "value"}
  dataCenterIds[]
```

### Templates

```
create-template
  name*          — (required)
  imageName*     — Docker image (required)
  isServerless   — true for serverless endpoints, false for pods
  containerDiskInGb
  volumeInGb / volumeMountPath
  ports[]
  env{}
  dockerEntrypoint[] / dockerStartCmd[]
  readme         — Markdown description
```

### Network Volumes

```
create-network-volume
  name*          — (required)
  size*          — GB, 1–4000 (required)
  dataCenterId*  — e.g. "US-TX-3" (required)

update-network-volume
  networkVolumeId*
  size           — New size; must be LARGER than current (no shrinking)
```

## Common Workflows

### 1. Inspect a Running Serverless Endpoint

```
list-endpoints(includeTemplate=true, includeWorkers=true)
  → find endpointId

get-endpoint(endpointId="abc123", includeWorkers=true)
  → check worker count, status, gpuTypeIds
```

### 2. Scale an Endpoint Up / Down

```
# Scale to zero when not in use (save cost)
update-endpoint(endpointId="abc123", workersMin=0, workersMax=3)

# Keep 1 warm worker for low-latency
update-endpoint(endpointId="abc123", workersMin=1, workersMax=5)

# Tune scale-down aggressiveness
update-endpoint(
  endpointId="abc123",
  idleTimeout=30,           # seconds before worker goes idle
  scalerType="QUEUE_DELAY", # scale up when queue backs up
  scalerValue=3             # target: process queue within 3s
)
```

### 3. Deploy a New Serverless Endpoint from a Docker Image

```
# Step 1: create a serverless template
create-template(
  name="10eros-i2v-v3",
  imageName="timpietruskyrunpod/comfyui-wizard:kd74g5ar81mx33r7nbyk9kk0p9872anv",
  isServerless=true,
  containerDiskInGb=20
)
  → returns templateId

# Step 2: create endpoint from template
create-endpoint(
  templateId="<templateId>",
  name="10eros-likeness-i2v",
  gpuTypeIds=["NVIDIA H100 NVL"],
  workersMin=0,
  workersMax=3
)
  → returns endpointId
```

### 4. Launch a GPU Pod (persistent, for dev/testing)

```
create-pod(
  name="comfyui-dev",
  imageName="runpod/worker-comfyui:5.8.4-base",
  gpuTypeIds=["NVIDIA RTX 4090"],
  gpuCount=1,
  cloudType="SECURE",
  containerDiskInGb=50,
  ports=["8188/http", "22/tcp"]
)
  → returns podId

get-pod(podId="xyz", includeMachine=true)
  → get IP, port, status
```

### 5. Pod Lifecycle

```
stop-pod(podId="xyz")    # pause billing (disk preserved)
start-pod(podId="xyz")   # resume
delete-pod(podId="xyz")  # permanent; disk wiped
```

### 6. Persistent Network Volume (shared across pods)

```
list-network-volumes()
  → check existing

create-network-volume(name="models-vol", size=200, dataCenterId="US-TX-3")
  → returns networkVolumeId

# Expand later (cannot shrink)
update-network-volume(networkVolumeId="vol123", size=500)
```

### 7. Private Docker Registry

```
create-container-registry-auth(
  name="my-dockerhub",
  username="myuser",
  password="mytoken"
)
  → returns containerRegistryAuthId — attach to templates/pods
```

## GPU Type ID Reference

Common IDs used in `gpuTypeIds[]`:

| Display Name | ID string |
|---|---|
| H100 NVL (96 GB) | `"NVIDIA H100 NVL"` |
| H100 SXM (80 GB) | `"NVIDIA H100 80GB HBM3"` |
| A100 SXM (80 GB) | `"NVIDIA A100 80GB"` |
| A100 PCIe (80 GB) | `"NVIDIA A100-SXM4-80GB"` |
| RTX 6000 Ada (48 GB) | `"NVIDIA RTX 6000 Ada Generation"` |
| RTX 4090 (24 GB) | `"NVIDIA GeForce RTX 4090"` |
| RTX 3090 (24 GB) | `"NVIDIA GeForce RTX 3090"` |

Use `list-endpoints(includeWorkers=true)` on an existing endpoint to see what ID RunPod assigned.

## Scaler Types

| `scalerType` | Behaviour | `scalerValue` meaning |
|---|---|---|
| `QUEUE_DELAY` | Scale up when queue age exceeds target | Target queue age in seconds |
| `REQUEST_COUNT` | Scale up when active requests exceed target | Request count per worker |

## Configuration

```
RUNPOD_API_KEY   — RunPod API key (runpod.io → Settings → API Keys)
```

Loaded automatically at session start via `.env` / `SessionStart` hook.

## Known Behaviours

1. **`workersMin=0`** — endpoint scales to zero between requests; cold start takes 30–120 s depending on image size and GPU availability.
2. **`workersMin=1`** — one worker stays warm; eliminates cold start at a flat cost.
3. **Templates are required for serverless endpoints** — you cannot create an endpoint directly from an image without first creating a template.
4. **Network volumes cannot shrink** — `update-network-volume` only accepts a `size` larger than the current value.
5. **`cloudType="COMMUNITY"`** on pods is cheaper but machines are shared-tenant; use `"SECURE"` for sensitive workloads.
6. **`delete-pod`** is irreversible and destroys the container disk — stop first if you want to inspect before deleting.
7. **`idleTimeout`** on endpoints is in seconds; default is 5 s. Set higher (30–60 s) for workflows with bursty traffic to avoid thrashing.
