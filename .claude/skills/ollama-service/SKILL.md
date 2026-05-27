---
name: ollama-service
description: Manage the Ollama service lifecycle — start, stop, restart, health check. Use before any mcp__ollama__* tool call to ensure the service is up. Wraps mcp__homebrew__* service controls with an Ollama-specific health ping.
---

# Ollama Service Management

Ollama runs as a Homebrew service. Use `mcp__homebrew__*` to control it, then verify
with a health ping before calling any `mcp__ollama__*` tool.

## Standard preamble (run before any ollama tool)

1. `mcp__homebrew__list_services()` — check `ollama` row for `started` / `stopped`
2. If stopped: `mcp__homebrew__start_service("ollama")` — allow ~3s to bind
3. Health ping:
```bash
curl -s http://localhost:11434/
# Expected: {"message":"Ollama is running"}
```

## Service controls

| Action | Tool |
|--------|------|
| Start | `mcp__homebrew__start_service("ollama")` |
| Stop | `mcp__homebrew__stop_service("ollama")` |
| Restart | `mcp__homebrew__restart_service("ollama")` |
| Status | `mcp__homebrew__list_services()` → filter for `ollama` |

## Check loaded models (VRAM usage)

```
mcp__ollama__ollama_ps()
```
Returns each loaded model with size-in-memory, processor (CPU/GPU), and expiry time.

## Notes

- Ollama auto-evicts models from VRAM after 5 min of inactivity. First inference after
  eviction adds 5–30s for reload.
- Default host: `http://127.0.0.1:11434` (set via `OLLAMA_HOST` in `.mcp.json`).
- See `ollama-mcp` skill for model pull/delete/list operations.
