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

### Subagents vs Agent Teams

| Pattern | Use when |
|---------|----------|
| **Background subagent** | Side task reports a summary back; workers don't need to talk to each other |
| **Agent Team** | Workers need to share findings, debate hypotheses, or coordinate on their own |
| **Skill** | Reusable prompt/workflow that runs in the main conversation context (no isolation) |

### Delegation default

> **Delegation default.** Any task whose discovery phase requires more than 2 read-only investigations (Read, Grep, Bash with read-only commands like `jq`/`grep`/`wc`/`find`/`ls`/`git log`, or any `mcp__*` read tool) MUST dispatch a background `Explore` (or `general-purpose`) subagent for that phase. The Lead consumes only the subagent's summary, never the raw output. "Judgment call" and "small task" are not exceptions — the threshold is the rule.

Enforced by `.claude/hooks/enforce-delegation.sh` (PreToolUse). Counter resets on any `Agent` dispatch in the session.

Subagents cannot spawn other subagents. Nested delegation must be chained from the main conversation (Lead) directly.

### Dispatching background subagents

Every `Agent({...})` call MUST include `run_in_background: true`. A `PreToolUse` hook blocks calls without it.

```python
Agent({
  description: "Short task label shown in the UI",
  prompt: "...",                        # fully self-contained — subagent has no conversation history
  subagent_type: "vastai-stack-deployer",  # optional: use a named .claude/agents/ definition
  model: "sonnet",                      # always explicit; see model resolution order below
  name: "bfs-deployer",                 # optional: makes the subagent resumable via SendMessage
  run_in_background: True,              # REQUIRED — hook blocks if missing
  isolation: "worktree",                # optional: isolated git checkout; auto-cleaned if no edits
  mode: "acceptEdits",                  # optional: override permission mode for this invocation
})
```

**Model resolution order** (first match wins):
1. `CLAUDE_CODE_SUBAGENT_MODEL` env var
2. Per-call `model` parameter
3. Subagent definition `model` frontmatter
4. Main conversation's model (inherited)

Always pass `model: "sonnet"` explicitly on background calls — never let a background worker inherit opus cost.

### The Lead end-turn rule

After dispatching background subagents:
1. **End the turn immediately.** The re-invocation (interrupt) mechanism only fires after the current turn ends. Blocking here deadlocks the workflow — the `Stop` hook is configured to approve when subagents are in flight.
2. **On re-invocation, triage the result:**
   - **Blocker** (error / missing dep / requires immediate action) → correct, spawn retry, notify user if needed → end turn
   - **Informational** (progress, partial result) → file it → end turn silently
3. **Never summarize subagent work unprompted.** Respond to user questions, but don't push unsolicited status updates.

### Resuming named subagents

Give a subagent a `name` to resume it later. After it stops, use `SendMessage` to continue it with full prior context instead of spawning a fresh instance (requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, already set in settings):

```
Use the stack-verifier subagent to check instance 38169505
[subagent completes]

Continue that verification and also check the Civitai LoRA
[Lead sends SendMessage to the same agent ID — full context preserved]
```

### Project subagent definitions

Custom definitions live in `.claude/agents/*.md` (project scope, version-controlled). Claude uses the `description` field to auto-delegate. The `background: true` frontmatter field makes a definition always run in background — aligns with the `PreToolUse` hook enforcement.

This project defines:
- `vastai-stack-deployer` — finds an offer, creates an instance, polls until running; reports instance ID + SSH URL
- `vastai-stack-verifier` — SSH-checks nodes, workflow JSON, models, and ComfyUI HTTP on a running instance

### Teammate rules (Agent Teams)

When operating as Lead with agent teams enabled:
1. Every `Agent({...})` call MUST include `run_in_background: true`
2. End the turn immediately after dispatching — do not block
3. On re-invocation: triage result, spawn next worker or end silently; never summarize unprompted
4. `TeammateIdle`, `TaskCompleted`, `TaskCreated` hooks enforce quality gates (see `settings.json`)
5. Use `TaskCreate` / `TaskUpdate` to coordinate shared work; teammates self-claim from the task list
6. Always use the Lead to clean up the team — never have a teammate run cleanup
