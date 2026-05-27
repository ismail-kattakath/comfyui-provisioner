---
name: hf-space-logs
description: Stream or snapshot HuggingFace Space container logs using the HF Logs API with $HF_TOKEN. Use when the user asks to watch, tail, check, or read logs for a HuggingFace Space — including build logs or runtime/run logs.
---

# HuggingFace Space Logs — Streaming via curl

Uses the HF Spaces Logs API (SSE stream). Requires `HF_TOKEN` in `.env`. Always run via `mcp__desktop-commander__start_process`, and always source `.env` first — desktop-commander starts its own shell and does **not** inherit Claude's exported env vars.

> **Project default Space:** `snorinGirl/10eros-likeness-i2v`

## Endpoints

| Log type | URL |
|----------|-----|
| Runtime (container stdout/stderr) | `https://huggingface.co/api/spaces/{owner}/{space}/logs/run` |
| Build logs | `https://huggingface.co/api/spaces/{owner}/{space}/logs/build` |

## Common Recipes

### Snapshot runtime logs (bounded)
```bash
source "$(git rev-parse --show-toplevel)/.env" && \
curl -sN --max-time 10 \
  -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/api/spaces/{owner}/{space}/logs/run"
```

### Stream runtime logs continuously
```bash
source "$(git rev-parse --show-toplevel)/.env" && \
curl -sN \
  -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/api/spaces/{owner}/{space}/logs/run"
```
Then poll with `mcp__desktop-commander__read_process_output(pid=...)`.

### Check build logs
```bash
source "$(git rev-parse --show-toplevel)/.env" && \
curl -sN --max-time 30 \
  -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/api/spaces/{owner}/{space}/logs/build"
```

### Extract only log text (strip SSE envelope)
```bash
source "$(git rev-parse --show-toplevel)/.env" && \
curl -sN --max-time 10 \
  -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/api/spaces/{owner}/{space}/logs/run" \
  | grep '^data:' \
  | sed 's/^data: //' \
  | jq -r '"\(.timestamp) \(.data)"'
```

## SSE Response Format

Each line is an SSE event:
```
data: {"data":"===== Application Startup at 2026-05-20 05:32:13 =====\n","timestamp":"2026-05-20T05:32:13Z"}
```

Fields:
- `data` — raw log line (may contain `\n`)
- `timestamp` — ISO 8601 UTC timestamp

## How to Call via desktop-commander

```python
mcp__desktop-commander__start_process(
  command='source "$(git rev-parse --show-toplevel)/.env" && curl -sN --max-time 15 -H "Authorization: Bearer $HF_TOKEN" "https://huggingface.co/api/spaces/{owner}/{space}/logs/run"',
  timeout_ms=20000
)
# Then read output with mcp__desktop-commander__read_process_output(pid=...)
```

## Notes

- **Always** prefix with `source "$(git rev-parse --show-toplevel)/.env" &&` when using desktop-commander — it does not inherit Claude's shell env.
- The stream stays open until the Space stops or `--max-time` is reached. Always set `--max-time` unless intentionally tailing indefinitely.
- `-N` disables curl's output buffering so lines arrive as they're emitted.
- `-s` suppresses the progress meter (cleaner output).
- Build logs can be large (tens of thousands of characters) — use `--max-time` and parse selectively.
