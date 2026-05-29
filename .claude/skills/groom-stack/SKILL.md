---
name: groom-stack
description: >
  Drive a ComfyUI stack repo from raw to "maximum purity": run preflight, lock provenance,
  declare MANUAL_MODELS for legitimately-manual refs, re-run strict preflight, and report a
  READY/NOT-READY verdict with a remediation plan. Use when onboarding a new stack or when a
  stack needs a quality audit before deployment.
---

# groom-stack

Given a stack repo path, drive it from its current state to the highest achievable
readiness tier, applying zero-trust and maximal pinning standards.

## Prerequisites

The following env vars must be set (zero-trust: no URL is anonymous):
- `GITHUB_TOKEN` — required for all github.com access (node SHAs, node pinning)
- `HF_TOKEN` — required for all huggingface.co access (model sha256 backfill)
- `CIVITAI_API_KEY` — required for all civitai.com access

Missing any of these against a stack that uses the corresponding service = NOT-READY.

## Inputs

- `STACK_DIR` — absolute path to the stack repo root (must contain `provisioner-config.sh`
  and `comfyui/`). Ask the user if not provided.

## Readiness ladder

| Tier | What it checks | Hard fail? |
|------|---------------|------------|
| T0 structural | `provisioner-config.sh` exists, parses, has all 5 arrays; `comfyui/` exists | Always |
| T1 referential | `WORKFLOW_MAP` files present in `comfyui/`; `ALIAS_MAP` targets exist in `NODE_MAP` | Always |
| T2 reachability | Node URLs reachable (HTTP 2xx), model URLs reachable | Always |
| T3 provenance | Model sha256 recorded or obtainable; Civitai version IDs present | Always |
| T4 coherence | No floating HF refs; all node pins are full SHAs; no unaccounted workflow refs | WARN by default, FAIL under `--strict` |

Exit codes: `0` READY | `2` NEEDS-FETCH | `1` NOT-READY.

## Steps

### Step 1 — Initial preflight (read-only)

```bash
bash scripts/preflight-stack.sh "$STACK_DIR"
```

Capture the full output. Identify every `[FAIL]`, `[WARN]`, and `[FETCH]` line.

**Interpret results:**
- `[FAIL]` lines are blockers — must be resolved before proceeding.
- `[WARN]` lines are purity issues — targeted by lock + MANUAL_MODELS.
- `[FETCH]` lines indicate models not yet on disk (normal pre-deployment state; exit code 2
  means NEEDS-FETCH, not broken).
- Exit code 1 = NOT-READY; stop and present the FAIL list to the user.
- Exit code 0 or 2 = proceed to Step 2.

Common T0/T1 failures and fixes:
- Missing array in `provisioner-config.sh`: add the array (even empty `ARRAY=()`)
- `WORKFLOW_MAP` file not in `comfyui/`: add the JSON file or remove the stale entry

### Step 2 — Lock provenance (backfill sha256 + pin nodes)

```bash
bash scripts/stack-lock.sh --write --pin-nodes "$STACK_DIR"
```

This writes `provisioner-config.sh` in place (a `.bak` copy is kept automatically).

What it does:
- For each `MODEL_MAP` entry with no sha256: queries HF `X-Linked-Etag` header and
  backfills the sha256 field. Upgrades T3 from "obtainable" to "recorded".
- With `--pin-nodes`: for each `NODE_MAP` entry with an empty pin field: resolves the
  remote's current HEAD SHA and writes it. Upgrades T4 node-pin purity.

**Known limitation:** `stack-lock` does not yet rewrite floating HF `/resolve/main/` refs
to `/resolve/<commit>/`. After locking, `--strict` will still emit a T4 WARN for those
refs. This is a known acceptable WARN — note it in the report and do not block on it.

Non-HF model URLs (direct HTTP, Civitai) are skipped by the lock tool; sha256 for those
must be recorded manually or via Civitai version metadata.

### Step 3 — Identify MANUAL_MODELS candidates

Re-run preflight after locking to get the updated picture:

```bash
bash scripts/preflight-stack.sh "$STACK_DIR"
```

Look for T4 `[WARN]` lines about workflow model references that have no `MODEL_MAP` or
`MODEL_MAP_CIVITAI` entry and are not already accounted for. These fall into two categories:

**Legitimately manual** (workflow assets that require out-of-band placement and cannot be
downloaded via the provisioner):
- User-supplied LoRAs (personal fine-tunes, dataset-specific weights)
- Assets with no public URL (private checkpoints, licensed-only releases)
- Large intermediate files that operators stage manually

**Fixable** (should be added to a map):
- Public HF models with known repo paths
- Civitai models with known version IDs

For each legitimately-manual asset, propose adding it to `provisioner-config.sh`:

```bash
# In provisioner-config.sh, alongside the other arrays:
MANUAL_MODELS=(
  "loras/custom/my-lora.safetensors"           # personal fine-tune — stage manually
  "checkpoints/private/base-model.safetensors" # licensed; no public URL
)
```

Present the proposed additions to the user and ask for confirmation before writing.
After confirmation, edit `provisioner-config.sh` using `Edit` to add or extend the
`MANUAL_MODELS` array.

### Step 4 — Strict preflight

```bash
bash scripts/preflight-stack.sh --strict "$STACK_DIR"
```

Review the output:
- Any remaining `[FAIL]` that is NOT the known HF floating-ref limitation must be resolved.
- The floating HF `/resolve/main/` → `/resolve/<commit>/` rewrite is not yet automated
  — note each occurrence as a remediation backlog item and do NOT block the verdict on it.
- All other T4 purity issues promoted to FAIL under `--strict` must be addressed before
  declaring the stack READY.

### Step 5 — Final verdict

Issue one of the following verdicts:

**READY**
> Stack `<name>` passed T0–T3 correctness and all T4 purity issues are resolved or
> accounted for. Pinning: `<N>` model sha256 recorded, `<N>` node commits pinned.
> Known limitation: `<N>` floating HF refs pending upstream fix to stack-lock.

**NEEDS-FETCH**
> Stack `<name>` is composable and all correctness gates pass. `<N>` model(s) not yet
> on disk (normal pre-deployment state). Deploy to a GPU instance to complete the fetch.

**NOT-READY**
> Stack `<name>` has `<N>` blocking issue(s):
> - `<FAIL line 1>`
> - `<FAIL line 2>`
> Remediation: `<specific action per item>`

## Zero-trust and pinning acceptance bar

A stack is not considered deployment-ready until:
1. All `NODE_MAP` entries have a full 40-char (or 64-char) hex commit SHA as the pin.
2. All `MODEL_MAP` HF entries have a 64-char hex sha256 recorded (or are tagged as
   MANUAL_MODELS where no sha256 is derivable).
3. All `MODEL_MAP_CIVITAI` entries have a numeric version ID.
4. No inline credentials appear anywhere in `provisioner-config.sh`.
5. All three tokens (`GITHUB_TOKEN`, `HF_TOKEN`, `CIVITAI_API_KEY`) are present as env
   vars at preflight time for any stack that uses the corresponding service.
