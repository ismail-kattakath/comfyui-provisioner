# comfyui-provisioner

## Project Overview

Generic, idempotent ComfyUI provisioner for cloud GPU rentals (VastAI, RunPod) and local dev. This repo is the **framework**; stack-specific configs (model picks, custom-node pins, workflow files) live in separate repos that consume this one.

Public repo: https://github.com/ismail-kattakath/comfyui-provisioner (MIT).

## Build / Test

```bash
# Syntax check the provisioner + all provider scripts
bash -n scripts/provision-comfyui.sh
for f in providers/*/onstart.sh providers/*/launch.sh; do
  [ -f "$f" ] && bash -n "$f" && echo "OK $f"
done

# Validate the VastAI template JSON
jq empty providers/vastai/template.json

# Dry-run against a sample stack config (sandbox COMFYUI_DIR, skip everything except the phase you're testing)
SANDBOX=/tmp/comfyui-sandbox
mkdir -p "$SANDBOX/user/default/workflows" "$SANDBOX/custom_nodes" "$SANDBOX/models"
HF_TOKEN=dummy \
COMFY_PIP=/usr/bin/false \
COMFYUI_DIR="$SANDBOX" \
PROVISIONER_CONFIG=/path/to/your/stack/provisioner-config.sh \
WORKFLOWS_SRC_DIR=/path/to/your/stack/comfyui \
SKIP_SYSTEM=1 SKIP_NODES=1 SKIP_MODELS=1 SKIP_UPDATE_ALL=1 SKIP_RESTART=1 \
bash scripts/provision-comfyui.sh
```

## Architecture

Tracked (part of the public repo):
- `scripts/provision-comfyui.sh` — generic 7-phase provisioner (preflight, system, tokens, nodes, workflows, models, manager-update, restart)
- `scripts/start-comfy.sh` — local ComfyUI launcher (dev helper)
- `providers/vastai/` — VastAI `--onstart-cmd` bootstrap + saved template + README
- `providers/runpod/` — stub (TODO)
- `providers/local/launch.sh` — macOS/Linux dev workflow
- `requirements.compiled`, `override.txt` — pinned base Python deps (uv-compiled)
- `README.md`, `LICENSE` (MIT)
- `.gitignore` — excludes `.env`, `.claude/settings.local.json`, caches, runtime artifacts

Untracked (local Claude Code workspace + dev env, gitignored where appropriate):
- `.claude/` — project config: hooks (`load-env.sh`), skills (civitai, huggingface, github, vast-ai, runpod, dockerhub, homebrew, ollama, context7, memory, etc.), settings
- `.env` / `.env.example` — local secrets (HF_TOKEN, CIVITAI_API_KEY, GH_TOKEN/GITHUB_PERSONAL_ACCESS_TOKEN, VAST_API_KEY, RUNPOD_API_KEY, SSH_KEY_FILE)
- `.mcp.json` — MCP server definitions for development tooling
- `.vscode/settings.json` — VS Code workspace
- `.worktreeinclude` — Claude Code worktree config
- `pyrightconfig.json` — pyright type-checker config
- `CLAUDE.md` — this file

## The contract this framework expects

A "stack repo" (separate from this one) ships at its root:
- `provisioner-config.sh` — exports five bash arrays: `NODE_MAP` (custom nodes + pins), `ALIAS_MAP` (legacy→canonical folder renames), `MODEL_MAP` (HF + public URL downloads), `MODEL_MAP_CIVITAI` (sha256-verified Civitai), `WORKFLOW_MAP` (workflows to stage)
- `comfyui/` — workflow JSON files (+ optional `comfy.settings.json`)

Provider bootstraps (`providers/*/onstart.sh`) clone both repos at runtime — provisioner-as-framework + stack-as-config — and wire them together via `PROVISIONER_CONFIG` + `WORKFLOWS_SRC_DIR`. The framework itself never references your stack by name.

## Conventions

- **Bash style:** `set -euo pipefail` at script top; explicit `trap` for error logging; `: "${VAR:?msg}"` for required env vars; never echo tokens
- **Idempotency:** every phase must be safe to re-run — clones become pulls, completed downloads short-circuit on size+sha256 match, partial downloads resume
- **Commits:** short imperative title under 70 chars; body explains the "why" not the "what"; never `--amend` unless the user explicitly asks
- **Secrets:** never commit `.env`. Use `.env.example` to document what env vars are expected.
- **Testing:** `bash -n` for syntax; dry-run with all SKIP flags except the phase you want to test for behavioral validation
- **Provider parity:** each `providers/<name>/onstart.sh` must produce identical end-state given the same `PROVISIONER_CONFIG` + tokens — the only differences are how the env is injected and how the service is restarted

## Important Notes

- **Phase 4 `WORKFLOWS_SRC_DIR` default** is `$SCRIPT_DIR/../../comfyui` — designed for a layout where the framework is a *sibling* of the stack repo's `comfyui/`. Provider bootstraps override this with an explicit path, so the default only matters for unusual standalone runs. Always set `WORKFLOWS_SRC_DIR` explicitly when invoking the provisioner outside a provider bootstrap.
- **VastAI direct SSH** — always resolve the SSH address via `vastai ssh-url <id>` (returns `ssh://root@<ip>:<port>`). The proxied `ssh8.vast.ai` address shown in `vastai show instances` drops connections at key exchange.
- **HF MCP transport** — the `huggingface` MCP server uses `http` transport; all other MCP servers use `stdio`. `sse` is deprecated and not used anywhere here.
- **Civitai downloads** require explicit `-o <path>` with curl — never `-J -O` (Civitai's Content-Disposition header is unreliable; `-J -O` produces wrong filenames).
- **PreToolUse hook may block credential strings** in `Write`/`Edit` calls. If a legitimate write hits the block, fall back to a Bash heredoc: `cat > file <<'EOF' … EOF`. Same applies to writes outside cwd (sibling-folder edits).
- **Stop hook policy** — only block `Stop` for work Claude can still finish now. Ending the turn with a user question is always acceptable; do not block on pending clarifications.
- **`provision.log` survives reruns** — onstart pipes through `tee -a`, never truncating. Inspect it across multiple boots of the same instance to see the full provisioning timeline.

## Tool Routing

Local project MCPs always override `MCP_DOCKER` equivalents. Never use `Bash(curl/wget)`, `WebFetch`, or `WebSearch` when a local MCP covers the operation.

| Task | Use |
|------|-----|
| Terminal / shell / files / processes | `mcp__desktop-commander__*` |
| Fetch a URL or web page | `mcp__fetch__fetch` |
| Library / API documentation | `mcp__context7__resolve-library-id` → `query-docs` |
| Web search / news | `mcp__duckduckgo__duckduckgo_search_text` |
| JSON query / filter | `mcp__mcp-jq__*` |
| JSON / YAML / TOML read-edit | `mcp__json-yaml-toml__*` |
| File diffs | `mcp__diff__*` |
| GitHub operations | `mcp__github__*` |
| HuggingFace search / docs | `mcp__huggingface__*` |
| HF file download | `hf download <repo_id> <filename> --repo-type model --local-dir <dir>` via `Bash` |
| Civitai models / images | `mcp__civitai__*` |
| Authenticated Civitai/HF page fetch | `curl -sL -H "Authorization: Bearer $TOKEN"` via desktop-commander |
| Docker Hub | `mcp__dockerhub__*` |
| Vast.ai GPU instances | `mcp__vast-ai__*` or `vastai` CLI |
| RunPod | `mcp__runpod__*` |
| Homebrew (macOS) | `mcp__homebrew__*` |
| Ollama (local LLM) | `mcp__ollama__*` |
| Memory across sessions | `mcp__memory__*` — `search_nodes` to recall, `create_entities`/`add_observations` to store |
| Multi-step planning | `mcp__sequentialthinking__sequentialthinking` first |

## Agent Spawning

Background subagents and team teammates MUST use `model: "sonnet"` — pass it explicitly on every `Agent({...})` call that runs with `run_in_background: true`. Foreground one-shot agents may inherit from the lead.

When operating as Lead in a team workflow:
1. Every `Agent({...})` call MUST include `run_in_background: true`. A PreToolUse hook blocks calls without it.
2. End the turn immediately after delegation. The notification re-invocation mechanism requires the current turn to end.
3. On re-invocation: check the result, decide whether to spawn another subagent or end silently. Don't summarize subagent work unprompted.
