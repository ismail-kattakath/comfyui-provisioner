---
description: >
  Deploy a ComfyUI stack repo on a fresh VastAI GPU instance. Searches for a
  suitable offer (24 GB VRAM, US/EU preferred, cheapest first), provisions the
  instance via the comfyui-provisioner onstart.sh pipeline, and polls until
  running. Records the deployment in memory. Use: /deploy-stack <stack-repo> [offer-id]
argument-hint: <stack-repo> [offer-id]
allowed-tools: Agent, Bash, Read, mcp__memory__*, mcp__sequentialthinking__*, mcp__vast-ai__*, PushNotification
---

# /deploy-stack

Lead orchestrator for deploying a ComfyUI stack on VastAI. Spawns a
`vastai-stack-deployer` background subagent and records the result.

## Usage

```
/deploy-stack <stack-repo> [offer-id]
```

**Examples:**
```
/deploy-stack ismail-kattakath/comfyui-stack-bfs-flux-klein-faceswap
/deploy-stack ismail-kattakath/comfyui-stack-10eros-likeness-i2v 34102223
```

---

## Step 0 — Pre-flight (do before spawning anything)

Arguments: `$ARGUMENTS`

1. **Memory search**: `mcp__memory__search_nodes` for `<stack-repo>` — check for any prior
   failed offer IDs, known GPU requirements, or VRAM notes for this stack.
2. **Parse args from `$ARGUMENTS`**: first token = `STACK_REPO` (required), second token =
   `OFFER_ID` (optional). If `$ARGUMENTS` is empty, ask the user once and wait.
3. **Notify user**: "Deploying `<STACK_REPO>` — searching for offer..." (or "using offer
   `<OFFER_ID>`...").

## Step 1 — Spawn deployer (background)

```python
Agent({
  description: f"Deploy {STACK_REPO} on VastAI",
  prompt: f"""
Deploy STACK_REPO={STACK_REPO} on VastAI using the comfyui-provisioner framework.

{f"Use OFFER_ID={OFFER_ID} — skip the offer search." if OFFER_ID else "Search for a suitable offer (24 GB VRAM, reliability > 0.95, US/EU preferred, cheapest first)."}

{"Avoid these previously-failed offer IDs: " + failed_offers if failed_offers else ""}

Report back:
- On success: instance ID, SSH URL, offer ID, GPU, location, $/hr
- On failure: what failed, instance ID if created (so it can be destroyed)
""",
  subagent_type: "vastai-stack-deployer",
  model: "sonnet",
  name: f"deployer-{STACK_REPO.split('/')[-1]}",
  run_in_background: True,
})
```

**End turn immediately after spawning.**

## Step 2 — On re-invocation (deployer finished)

**Success path:**
1. Record in memory:
   ```
   create_entities: [{ name: f"vastai-{instance_id}", entityType: "VastAIInstance",
     observations: [f"stack={STACK_REPO}", f"ssh={SSH_URL}", f"offer={OFFER_ID}",
                    f"gpu={GPU}", f"dph={DPH}", f"deployed={date}"] }]
   ```
2. Report to user:
   ```
   ✅ Deployed: <STACK_REPO>
   Instance: <ID>  SSH: <URL>
   Offer: <GPU>, <location>, $<dph>/hr
   ```
3. Offer to run `/verify-stack <instance_id>` next.

**Failure path:**
1. If an instance was created (even in error state): record the failed offer ID in memory
   so it's avoided on retry.
2. `yes | vastai destroy instance <ID>` if instance exists and is in error state.
3. Report to user with options:
   - Retry on a different offer
   - Retry with a specific offer ID
   - Abort

## Orchestration rules

- **Never block the Stop hook while waiting for the deployer** — the notification
  re-invocation mechanism requires the current turn to end.
- **Offer failures**: if the deployer reports a load timeout (>30 min), record the offer
  ID as unreliable in memory and offer retry on a new offer.
- **Token safety**: never echo `HF_TOKEN`, `CIVITAI_API_KEY`, `GH_TOKEN`, or `VAST_API_KEY`
  in any message to the user.
