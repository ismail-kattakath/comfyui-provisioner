---
description: >
  SSH-verify a running VastAI ComfyUI instance. Checks custom_nodes directories,
  workflow JSON, model files (>100 MB), and ComfyUI HTTP 200. Reports explicit
  PASS or FAIL with evidence, and records the result in memory.
  Use: /verify-stack <instance-id> [stack-repo]
argument-hint: <instance-id> [stack-repo]
allowed-tools: Agent, Bash, Read, mcp__memory__*, PushNotification
---

# /verify-stack

Lead orchestrator for verifying a deployed ComfyUI stack on VastAI. Spawns a
`vastai-stack-verifier` background subagent and records the PASS/FAIL result.

## Usage

```
/verify-stack <instance-id> [stack-repo]
```

**Examples:**
```
/verify-stack 38169505
/verify-stack 38169505 ismail-kattakath/comfyui-stack-bfs-flux-klein-faceswap
```

---

## Step 0 — Pre-flight

Arguments: `$ARGUMENTS`

1. **Parse args from `$ARGUMENTS`**: first token = `INSTANCE_ID` (required), second token =
   `STACK_REPO` (optional).
2. **Memory lookup**: if `STACK_REPO` not supplied, search `mcp__memory__search_nodes`
   for entity `vastai-<instance_id>` to retrieve the stack it was deployed with.
3. **Confirm instance is running** via the JSON API list endpoint:
   ```bash
   curl -fsS -H "Authorization: Bearer $VAST_API_KEY" \
     "https://console.vast.ai/api/v0/instances/" | python3 -c "
   import json,sys
   for i in json.load(sys.stdin).get('instances',[]):
       if str(i['id']) == '<INSTANCE_ID>':
           print(i.get('actual_status'), i.get('cur_state')); break
   "
   ```
   If `actual_status` is not `running`, report and abort — verifier will only get
   "connection refused".

## Step 1 — Spawn verifier (background)

```python
Agent({
  description: f"Verify instance {INSTANCE_ID} ({STACK_REPO or 'unknown stack'})",
  prompt: f"""
SSH-verify VastAI ComfyUI instance INSTANCE_ID={INSTANCE_ID}.
STACK_REPO={STACK_REPO or "unknown — check what's actually installed"}.

Report an explicit PASS or FAIL with specific evidence:
- Which custom_nodes directories are present/missing
- Whether the workflow JSON is staged
- How many model files >100 MB exist
- ComfyUI HTTP status code
- Number of registered node classes (from /object_info)
""",
  subagent_type: "vastai-stack-verifier",
  model: "sonnet",
  name: f"verifier-{INSTANCE_ID}",
  run_in_background: True,
})
```

**End turn immediately after spawning.**

## Step 2 — On re-invocation (verifier finished)

**PASS path:**
1. Add observation to the instance memory entity:
   ```
   add_observations: [{ entityName: f"vastai-{INSTANCE_ID}",
     observations: [f"verified=PASS", f"verified_at={date}",
                    f"nodes={N}", f"models={N}", f"comfyui=HTTP200"] }]
   ```
2. Report to user:
   ```
   ✅ PASS — instance <ID> (<STACK_REPO>)
      Nodes: <list>
      Workflow: <filename>
      Models: <N> files >100 MB
      ComfyUI: HTTP 200, <N> classes
   ```

**FAIL path:**
1. Add observation to memory: `verified=FAIL`, specific missing items.
2. Report to user with specific failures and remediation options:
   - **Missing nodes**: `ssh ... 'bash /workspace/reprovision.sh'` to re-run provisioning
   - **Missing models**: check `provision.log` for download errors; re-run or re-deploy
   - **ComfyUI unreachable**: check if still booting (`tail -f /workspace/provision.log`)
   - **Everything missing**: destroy + redeploy on a different offer

## Orchestration rules

- **Never block the Stop hook** — end turn after spawning and wait for notification.
- **SSH refused** is a FAIL, not a retry-worthy condition — report it clearly.
- **If verifier times out**: treat as FAIL, suggest manual SSH check.
