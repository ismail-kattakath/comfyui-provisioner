# Preflight reference

`scripts/preflight-stack.sh` is a **read-only, GPU-free** checker that validates a ComfyUI stack repo before you rent a GPU. It never downloads model bytes — only probes URLs with HEAD or a 1-byte range GET.

See also: [Stack authoring guide](STACK-AUTHORING.md) | [README](../README.md#stack-readiness-preflight)

---

## Usage

```bash
scripts/preflight-stack.sh [--strict] [--verify-pins] [--json] [STACK_DIR]
```

| Argument / flag | Meaning |
|---|---|
| `STACK_DIR` | Path to the stack repo root (default: `$PWD`). Must contain `provisioner-config.sh` and `comfyui/`. |
| `--strict` | Promote purity WARNs (unpinned node commits, unrecorded sha256, floating HF `/resolve/main/` refs) to hard FAILs. Use in CI after running `stack-lock.sh --write`. |
| `--verify-pins` | Network-verify each non-empty NODE_MAP commit SHA is actually fetchable from its remote (one shallow `git fetch --depth 1` per node). Slower; use before a release. |
| `--json` | Emit a single-line machine-readable JSON verdict instead of human text. |
| `-h` / `--help` | Print the script header and exit. |

### Optional environment variables

| Variable | Effect |
|---|---|
| `COMFYUI_DIR` | If set and `$COMFYUI_DIR/models/` exists, also reports which models are already on disk and verifies their sha256. |
| `PREFLIGHT_ALLOW` | Space-separated model basenames the workflow may reference without a MAP entry (e.g. node-managed or baked-in-image weights). Suppresses T4 warnings for those names. |

### Required tokens (zero-trust)

Preflight always authenticates to every host it contacts. A token that is required by the stack but absent is a hard NOT-READY failure — never a silent skip.

| Host | Token variable |
|---|---|
| `github.com` | `GITHUB_TOKEN` |
| `huggingface.co` | `HF_TOKEN` |
| `civitai.com` | `CIVITAI_API_KEY` |

---

## Exit codes

Modelled on `terraform plan -detailed-exitcode` so CI scripts can branch on the result without parsing text.

| Code | Name | Meaning |
|---|---|---|
| **0** | READY | All correctness gates pass; nothing blocking. |
| **1** | NOT-READY | At least one hard failure: dead URL, missing token, hash mismatch on disk, missing required array, or (under `--strict`) a purity violation. |
| **2** | NEEDS-FETCH | Correctness gates pass and everything is reachable, but one or more resources are not yet on disk / recorded in the lock. Reachable, composable — just needs provisioning. |

---

## Output lines

Each check emits a tagged line:

| Tag | Meaning |
|---|---|
| `[OK]` | Check passed. |
| `[WARN]` | Purity or advisory finding. Does NOT affect the exit code unless `--strict` is active. |
| `[FAIL]` | Hard failure. Sets exit code 1. |
| `[FETCH]` | Resource is reachable but absent from disk. Sets exit code 2 (unless there is also a FAIL). |

---

## Tier ladder

Preflight runs five tiers in sequence. T0–T3 are **correctness** gates; T4 is **advisory**. Purity is a separate dimension (WARN by default, FAIL under `--strict`).

### T0 — Structural

**Checks:**

- `provisioner-config.sh` exists at `STACK_DIR`.
- `comfyui/` directory exists at `STACK_DIR`.
- Config sources without errors.
- All five required bash arrays are declared: `NODE_MAP`, `ALIAS_MAP`, `MODEL_MAP`, `MODEL_MAP_CIVITAI`, `WORKFLOW_MAP`.

**Abort behaviour:** If T0 fails, the run stops immediately with exit 1 — later tiers depend on the arrays being loadable.

**Output example:**

```
== T0 structural ==
  [OK]      config sources cleanly; 5 arrays defined (NODE=12 ALIAS=3 MODEL=8 CIVITAI=4 WORKFLOW=2)
```

---

### Auth (zero-trust)

After T0, preflight scans every URL in `NODE_MAP`, `MODEL_MAP`, and `MODEL_MAP_CIVITAI` and determines which token variables are required. Then:

- Each required token that is present → `[OK]`.
- Each required token that is absent → `[FAIL]`.
- It also scans `provisioner-config.sh` for inline credentials (embedded tokens, `user:pass@` URLs, Bearer strings). Any match → `[FAIL]`.

---

### T1 — Referential integrity

**Checks:**

- Every file listed in `WORKFLOW_MAP` (first `|`-field) exists under `comfyui/`.
- Every `ALIAS_MAP` target matches a `NODE_MAP` folder name (case-insensitive, to allow deliberate case-only renames).
- `NODE_MAP` folder names are unique (no duplicates).
- Every `MODEL_MAP_CIVITAI` entry carries a valid 64-hex sha256 in its third `|`-field.

All T1 checks are purely local (no network).

---

### T2 — Reachability

**Checks (network, read-only):**

- **HuggingFace models** (`MODEL_MAP`): authenticated HEAD via `$HF_TOKEN`; expects HTTP 200. Collects `X-Linked-Etag` for T3.
- **Civitai models** (`MODEL_MAP_CIVITAI`): authenticated 1-byte range GET (`-r 0-0`) via `$CIVITAI_API_KEY`; expects 200 or 206. (Civitai's R2 presigned URLs reject HEAD with 403 but answer 206 to range GET — standard HEAD is not used here.)
- **Non-HF public URLs** (in `MODEL_MAP`): unauthenticated HEAD; expects 200.
- **Node git repos** (`NODE_MAP`): `git ls-remote` via `$GITHUB_TOKEN` (for `github.com` URLs). If `--verify-pins` is set, also does a shallow `git fetch --depth 1` of the recorded commit SHA to confirm it has not been garbage-collected.

---

### T3 — Provenance

T3 runs interleaved with T2 (each model is checked for reachability and sha256 in one pass).

**Checks:**

- If the `MODEL_MAP` entry already has a 64-hex sha256 in field 3 → **recorded** (best).
- Otherwise, if the HF HEAD response included `X-Linked-Etag` with a valid sha256 → **obtainable** (good; run `stack-lock.sh --write` to promote to recorded).
- If neither → `[WARN]` (integrity unverifiable).
- Tally: `sha256 recorded:<n>  obtainable-via-etag:<n>  hf-total:<n>`.

**Purity WARNs (→ FAIL under `--strict`):**

- `MODEL_MAP` entry for HF uses a floating ref (`/resolve/main/` or `/resolve/master/`): pin to a commit revision instead.
- `MODEL_MAP` entry has a sha256 that is obtainable but not yet recorded: run `stack-lock.sh --write`.
- `MODEL_MAP_CIVITAI` entry URL is not a versioned `/api/download/models/<id>` URL.
- `NODE_MAP` entry has no commit pin (empty field 2) or the pin is not a full hex SHA.

**On-disk check (optional, requires `COMFYUI_DIR`):**

When `COMFYUI_DIR` is set and its `models/` subdirectory exists, each model entry is additionally checked on disk:

- File present + sha256 matches → `[OK] on-disk + verified`.
- File present but no sha256 available → `[WARN] on-disk but no sha to verify`.
- File absent → `[FETCH] not on disk` (contributes to exit code 2).
- File present but sha256 differs → `[FAIL] HASH MISMATCH on disk`.

---

### T4 — Coherence (advisory)

T4 cross-references the model filenames that each deployed workflow JSON actually references against the union of:

- All `MODEL_MAP` entries (full relative path and basename).
- All `MODEL_MAP_CIVITAI` entries.
- All `MANUAL_MODELS` entries declared in `provisioner-config.sh`.
- All basenames in `PREFLIGHT_ALLOW`.

Note nodes (type contains `note` case-insensitively, including `MarkdownNote`) are excluded before scanning — their text content is documentation, not loader inputs.

Any model filename referenced by a workflow but absent from all of the above produces `[WARN] workflow references '<file>' — not in any MAP, allowlist, or MANUAL_MODELS`. T4 never produces a FAIL; it is advisory.

**Known examples of legitimate T4 candidates:**

- Node-managed weights (e.g. the LTX audio vocoder fetched at runtime by ComfyUI-LTXVideo) — suppress with `PREFLIGHT_ALLOW`.
- LoRA version drift (e.g. a workflow hardcoded to `head_swap_step4000.safetensors` while MODEL_MAP ships `step3500`).
- Manual extras (`next-scene_lora.safetensors`, `SexGod_*.safetensors`, etc.) — declare in `MANUAL_MODELS`.

---

## JSON output (`--json`)

When `--json` is set, a single JSON object is printed and the same exit codes apply:

```json
{
  "stack": "my-stack",
  "verdict": "NEEDS-FETCH",
  "strict": false,
  "fails": [],
  "warns": ["2 HF model(s) have no RECORDED sha256 — run stack-lock to pin"],
  "needsFetch": ["not on disk: loras/my-lora.safetensors"]
}
```

`verdict` is one of `"READY"`, `"NEEDS-FETCH"`, or `"NOT-READY"`.

---

## Calibration philosophy

The correctness tiers (T0–T3) are **calibrated against a known-good corpus** — all comfyui-stack-* repos pass T0–T3 in default mode. This means:

- If a T0–T3 check **fails on a known-good stack**, the checker is wrong — file a bug, do not tweak the stack to work around it.
- If a T0–T3 check **passes on a bad stack**, the checker has a gap — add a new check.

Purity WARNs are not calibrated in the same way: they are a **remediation backlog** toward maximum purity. A warning-free run in `--strict` mode is the gold standard, but real stacks are expected to have some purity debt.

---

## Locking: `stack-lock.sh`

`scripts/stack-lock.sh` is the companion write tool. It backfills provenance so preflight T3 moves from "obtainable" to "recorded":

```bash
# Dry-run (default) — prints what would change, touches nothing
scripts/stack-lock.sh [STACK_DIR]

# Pin empty NODE_MAP commits to current remote HEAD
scripts/stack-lock.sh --pin-nodes [STACK_DIR]

# Apply changes to provisioner-config.sh (keeps .bak)
scripts/stack-lock.sh --write [STACK_DIR]
scripts/stack-lock.sh --write --pin-nodes [STACK_DIR]
```

After writing, re-run preflight with `--strict` to confirm all purity gates pass:

```bash
scripts/stack-lock.sh --write --pin-nodes --pin-hf-rev /path/to/stack
scripts/preflight-stack.sh --strict /path/to/stack
```

### Pinning HF floating refs with `--pin-hf-rev`

`stack-lock.sh` supports `--pin-hf-rev` to automatically rewrite floating HF `/resolve/main/` (or `/resolve/master/`) URLs to pinned `/resolve/<full-40-hex-commit>/` revision URLs. It captures the exact commit SHA from HF's `X-Repo-Commit` response header on an authenticated HEAD request and rewrites the URL in place.

The canonical full-purity lock command is:

```bash
scripts/stack-lock.sh --write --pin-nodes --pin-hf-rev /path/to/stack
scripts/preflight-stack.sh --strict /path/to/stack
```

After running both flags, `preflight --strict` is expected to exit 0. Only genuine T4 advisory coherence WARNs may remain (e.g. legitimately-manual models not in any MAP — declare those via `MANUAL_MODELS`).
