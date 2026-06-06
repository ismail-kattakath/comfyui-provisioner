---
description: >
  Silently watch the Syncthing-mirrored ComfyUI logs of a given stack and
  interrupt only when an error appears. Auto-stops after idle/wall-clock cap.
argument-hint: <STACK_REPO>  (owner/repo or git URL)
allowed-tools: Task, Bash, Read, Grep
---

# /watch-comfyui-logs

Dispatch a single background subagent to tail the local Syncthing mirror of
a vast.ai instance's ComfyUI logs for a specific stack. The agent runs with
`run_in_background: true` so it doesn't block the main loop, stays quiet on
normal progress, and interrupts only on real failure signals.

**`STACK_REPO` is required and never assumed** — every invocation specifies
exactly which stack's logs to watch. Parse `$ARGUMENTS`: first token is
`STACK_REPO`. If missing, refuse and ask the user.

## Step 0 — Ensure stack present locally + derive log paths

Before dispatching the watcher, ensure the stack is cloned locally so its
`logs/` directory exists at the expected sibling path:

```bash
PROVISIONER_ROOT="$(git rev-parse --show-toplevel)"
ENSURE_OUT="$("$PROVISIONER_ROOT/scripts/ensure-stack.sh" "$STACK_REPO")" || {
  echo "ensure-stack failed for $STACK_REPO; aborting"; exit 1
}
eval "$(echo "$ENSURE_OUT" | tail -1)"   # exports STACK_DIR
COMFYUI_LOG="$STACK_DIR/logs/comfyui.log"
API_LOG="$STACK_DIR/logs/api-wrapper.log"
```

If `$STACK_DIR/logs/` doesn't exist or is empty, the Syncthing log pair was
never set up for this stack — report:

> Log Syncthing pair not set up for `<STACK_REPO>`. Run
> `/pair-vastai-logs <instance-id>` first.

…and exit cleanly without dispatching the watcher.

## Step 1 — Dispatch the background watcher

Spawn a single `general-purpose` subagent with `run_in_background: true`.
Brief it with the exact `$COMFYUI_LOG` and `$API_LOG` paths derived above
(absolute paths — no globs, no env vars left for the agent to resolve).

## Watch loop (the agent does this)

1. Record current EOF byte offsets of both files.
2. Every 12–15 seconds, read the new bytes appended since last poll (`wc -c`
   for current size, `tail -c <delta>` for the delta).
3. Pattern-match the new bytes.

## Interrupt classes — return to parent immediately

Any of the following in new bytes ⇒ stop polling, report:

- `Traceback (most recent call last):`
- `OutOfMemoryError` / `CUDA out of memory` / `torch.OutOfMemoryError`
- `Error occurred when executing` (ComfyUI's node-error prefix)
- Non-empty `node_errors` object in a `/prompt` response
- `Prompt has no outputs`
- `Killed`, `Aborted (core dumped)`
- `Connection refused` on the ComfyUI port
- ComfyUI process exit markers: `got signal`, `Shutting down`, `Server stopped`

Report shape on interrupt:
- Which file fired
- Up to 40 lines of surrounding context (lead-in + trailing)
- One-sentence classification (e.g. "CUDA OOM in KSampler", "Validation
  rejected — missing input X")
- One specific recommended next action

## Quiet-success patterns — track silently

- `got prompt` (queue accepted)
- `Prompt executed in <N>s` (success)
- model load lines

## Auto-stop conditions

- 10 minutes with no new bytes in BOTH files
- 60 minutes total wall-clock (safety cap)

On auto-stop: short summary (prompts seen queue/complete, longest idle gap,
final file sizes, error count = 0).

## Constraints

- DO NOT SSH to the instance. The Syncthing mirror is source of truth.
- DO NOT touch files outside `$STACK_DIR/logs/`.
- DO NOT modify the stack repo's tracked files (workflow JSON, etc.).
- BE QUIET. Only emit text on interrupt or auto-stop.

## Composes with

- `/pair-vastai-logs <id>` — must run first to establish the Syncthing log
  mirror that this command watches.
- `/ensure-stack <STACK_REPO>` — already called as Step 0; no separate
  invocation needed.
