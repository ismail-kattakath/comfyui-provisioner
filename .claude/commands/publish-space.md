# /publish-space — one-command HuggingFace Space from a stack tool

Predictively scaffold (and optionally deploy) a Gradio HuggingFace Space that wraps
a stack's single-image Python tool. Wraps `scripts/make-space.py` (framework-level,
reusable across stacks). The tool is introspected for its parameters; an optional
sidecar manifest `<tool>.space.json` overrides labels/ranges/docs.

## Usage

```
/publish-space <stack> <tool> [--deploy] [--public] [--space-id USER/NAME]
```

- `<stack>` — stack name (`iclight-v2v` → `/workspaces/comfyui-stack-iclight-v2v`) or an explicit path.
- `<tool>`  — tool basename; resolves to `<stack>/scripts/<tool>.py` (+ `<tool>.space.json` if present).
- `--deploy` — actually create + push the Space (default: scaffold only).
- `--public` — make the Space public (default: **private**).
- `--space-id` — override the HF repo id (default `snorinGirl/<stack>-<tool>`).

## What it does

1. **Resolve** the stack dir, tool file (`<stack>/scripts/<tool>.py`), and manifest.
   If the tool file is missing, stop and list `<stack>/scripts/*.py`.
2. **Scaffold** into `<stack>/spaces/<space-name>/` (no deploy yet):
   ```bash
   python3 "$(git -C /workspaces/comfyui-provisioner rev-parse --show-toplevel)/scripts/make-space.py" \
     --tool <stack>/scripts/<tool>.py \
     --space-id <USER/NAME> \
     --out <stack>/spaces/<space-name>
   ```
   Then `python3 -m py_compile <out>/app.py` to verify the generated app.
3. **Report** the generated files (`app.py`, the copied tool, `requirements.txt`, `README.md`)
   and the detected parameters.
4. **Deploy** only when `--deploy` is passed AND the user has confirmed visibility:
   re-run the same command with `--deploy` appended (and `--public` if chosen).
   Deploy uses `HF_TOKEN` from `.env` via `huggingface_hub` (pip-install it if absent).

## Privacy (mandatory)

- Default the Space to **private**. Only go `--public` on explicit user opt-in.
- **Never bake the user's personal input photos into the Space.** If an example image is
  wanted, generate a synthetic one; never copy from a stack's `input/` or `output/`.

## Notes

- Tool convention: the wrapped function is `fn(input_path, output_path, *tunables)`
  (default fn name `grade`; override in the manifest `"fn"` or with `--fn`).
- Hardware defaults to `cpu-basic` (free) — suitable for pure-Python/numpy/PIL/cv2 tools.
  GPU-backed ComfyUI *workflows* are NOT covered yet (they need a GPU backend; future work).
- The scaffolder copies the tool into the Space so it is self-contained. Re-run to regenerate
  after the tool changes — the generated `app.py` is not meant to be hand-edited.
- Deploying is outward-facing: confirm with the user before the `--deploy` push.
