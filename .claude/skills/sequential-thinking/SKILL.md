---
name: sequential-thinking
description: Break down complex problems, plan multi-step tasks, or debug tricky issues using structured, revisable chain-of-thought reasoning.
---

# Sequential Thinking — 1 Tool Reference

Configured in `.mcp.json` as `"sequentialthinking"` (stdio, `npx -y @modelcontextprotocol/server-sequentialthinking`). No authentication required.

> **MCP_DOCKER priority**: When the `MCP_DOCKER` server is available, prefer `mcp__MCP_DOCKER__sequentialthinking` over `mcp__sequentialthinking__sequentialthinking`.

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|-----------|
| Step through a reasoning chain | `sequentialthinking` | `thought`, `thoughtNumber`, `totalThoughts`, `nextThoughtNeeded` |
| Revise an earlier thought | `sequentialthinking` | `isRevision=true`, `revisesThought=<n>` |
| Branch from a thought | `sequentialthinking` | `branchFromThought=<n>`, `branchId="<label>"` |
| Extend beyond original estimate | `sequentialthinking` | `needsMoreThoughts=true` |

## Common Workflows

### 1. Breaking Down a Complex Engineering Task
```
sequentialthinking(thought="Understand the goal: ...", thoughtNumber=1, totalThoughts=5, nextThoughtNeeded=true)
sequentialthinking(thought="Identify constraints: ...", thoughtNumber=2, totalThoughts=5, nextThoughtNeeded=true)
sequentialthinking(thought="Outline steps: ...", thoughtNumber=3, totalThoughts=5, nextThoughtNeeded=true)
sequentialthinking(thought="Consider risks: ...", thoughtNumber=4, totalThoughts=5, nextThoughtNeeded=true)
sequentialthinking(thought="Final plan: ...", thoughtNumber=5, totalThoughts=5, nextThoughtNeeded=false)
```

### 2. Debugging a Subtle Multi-File Issue
```
sequentialthinking(thought="Reproduce: ...", thoughtNumber=1, totalThoughts=4, nextThoughtNeeded=true)
sequentialthinking(thought="Trace execution path: ...", thoughtNumber=2, totalThoughts=4, nextThoughtNeeded=true)
# Realise thought 2 was wrong — revise it
sequentialthinking(thought="Corrected trace: ...", thoughtNumber=3, totalThoughts=5, nextThoughtNeeded=true, isRevision=true, revisesThought=2)
sequentialthinking(thought="Root cause identified: ...", thoughtNumber=4, totalThoughts=5, nextThoughtNeeded=true)
sequentialthinking(thought="Fix: ...", thoughtNumber=5, totalThoughts=5, nextThoughtNeeded=false)
```

### 3. Planning an Architecture Decision with Trade-Offs
```
sequentialthinking(thought="Define options A, B, C", thoughtNumber=1, totalThoughts=4, nextThoughtNeeded=true)
# Branch to explore option A deeply
sequentialthinking(thought="Option A pros/cons: ...", thoughtNumber=2, totalThoughts=4, nextThoughtNeeded=true, branchFromThought=1, branchId="option-a")
# Branch to explore option B
sequentialthinking(thought="Option B pros/cons: ...", thoughtNumber=2, totalThoughts=4, nextThoughtNeeded=true, branchFromThought=1, branchId="option-b")
sequentialthinking(thought="Recommendation: ...", thoughtNumber=3, totalThoughts=4, nextThoughtNeeded=true)
sequentialthinking(thought="Final decision: ...", thoughtNumber=4, totalThoughts=4, nextThoughtNeeded=false)
```

## Configuration

No authentication required. No environment variables needed.

## Known Behaviors

1. `totalThoughts` is an estimate — set `needsMoreThoughts=true` on the last planned thought to extend the chain without losing context from earlier thoughts.
2. Revision does not delete the original thought — both are preserved; use `revisesThought` to signal which earlier thought the revision supersedes.
3. Branches are independent sequences identified by `branchId` — each branch restarts `thoughtNumber` from the branch point; keep IDs short and descriptive.
4. `nextThoughtNeeded=false` signals the chain is complete — always terminate cleanly to avoid dangling reasoning chains.
5. Best used for tasks where intermediate reasoning steps are load-bearing (architecture, debugging, planning) rather than simple lookups.
