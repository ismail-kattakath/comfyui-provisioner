---
name: memory-mcp
description: Store, retrieve, and manage persistent knowledge across sessions using a local knowledge graph — entities, relations, and observations that survive conversation resets.
---

# Memory MCP — 9 Tools Reference

Configured in `.mcp.json` as `"memory"` (stdio, `npx -y @modelcontextprotocol/server-memory`). No authentication required.

> **MCP_DOCKER priority**: When the `MCP_DOCKER` server is available, prefer the `mcp__MCP_DOCKER__*` equivalents: `mcp__MCP_DOCKER__create_entities`, `mcp__MCP_DOCKER__create_relations`, `mcp__MCP_DOCKER__add_observations`, `mcp__MCP_DOCKER__read_graph`, `mcp__MCP_DOCKER__search_nodes`, `mcp__MCP_DOCKER__open_nodes`, `mcp__MCP_DOCKER__delete_entities`, `mcp__MCP_DOCKER__delete_observations`, `mcp__MCP_DOCKER__delete_relations`.

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|-----------|
| Create named entities | `create_entities` | `entities[]` with `name`, `entityType`, `observations[]` |
| Link entities together | `create_relations` | `relations[]` with `from`, `to`, `relationType` |
| Append facts to an entity | `add_observations` | `observations[]` with `entityName`, `contents[]` |
| Read the full graph | `read_graph` | (none) |
| Search entities by keyword | `search_nodes` | `query` (string) |
| Retrieve specific entities | `open_nodes` | `names` (string[]) |
| Delete entities | `delete_entities` | `entityNames` (string[]) |
| Remove specific facts | `delete_observations` | `deletions[]` with `entityName`, `observations[]` |
| Remove specific relations | `delete_relations` | `relations[]` with `from`, `to`, `relationType` |

## Common Workflows

### 1. Store Project Context Across Sessions
```
create_entities(entities=[
  {name: "your-project", entityType: "project", observations: ["ComfyUI/EasyFlow workflow collection", "targets LTX-Video with GGUF quantization"]},
  {name: "YourEntity", entityType: "workflow", observations: ["EasyFlow v1.7", "uses GGUF quantized LTXV 2.3 checkpoint"]},
  {name: "YourArchDecision", entityType: "decision", observations: ["chose stdio MCP over HTTP for local servers", "reason: no auth overhead"]}
])

create_relations(relations=[
  {from: "your-project", to: "YourEntity", relationType: "contains"},
  {from: "your-project", to: "YourArchDecision", relationType: "documented-in"}
])
```

### 2. Build a Knowledge Graph of Model Relationships
```
create_entities(entities=[
  {name: "LTXV-2.3", entityType: "checkpoint", observations: ["LTX-Video 2.3", "path: models/checkpoints/ltxv-2.3.gguf"]},
  {name: "motion-lora-v1", entityType: "lora", observations: ["motion enhancement LoRA", "weight: 0.8"]}
])

create_relations(relations=[
  {from: "YourEntity", to: "LTXV-2.3", relationType: "uses-checkpoint"},
  {from: "YourEntity", to: "motion-lora-v1", relationType: "uses-lora"}
])

# Later: find what a workflow uses
search_nodes(query="YourEntity")
open_nodes(names=["YourEntity", "LTXV-2.3"])
```

### 3. Track Debugging State
```
# Record findings as you discover them
create_entities(entities=[
  {name: "bug-node-id-collision", entityType: "bug", observations: ["node IDs 42 and 43 collide after workflow merge", "first seen 2026-05-19"]}
])

add_observations(observations=[
  {entityName: "bug-node-id-collision", contents: ["root cause: EasyFlow auto-assigns from 1; merge resets counter", "fix: re-export after merge"]}
])

# When resolved, clean up
delete_entities(entityNames=["bug-node-id-collision"])
```

## Configuration

No authentication required. No environment variables needed.

The knowledge graph is persisted locally by the `@modelcontextprotocol/server-memory` package in a file within the npx cache. Data persists across Claude Code sessions as long as the npx cache is intact.

## Known Behaviors

1. Entity names are case-sensitive and serve as primary keys — use consistent naming conventions (e.g. kebab-case) to avoid creating duplicate entities.
2. `read_graph` returns the entire graph — on large graphs this can be verbose; prefer `search_nodes` or `open_nodes` when you know what you're looking for.
3. `delete_entities` also removes all relations involving those entities — there is no cascade warning; confirm before deleting shared hub entities.
4. `add_observations` appends to existing observations without deduplication — avoid calling it repeatedly with the same content, as duplicates accumulate silently.
5. `search_nodes` performs fuzzy matching across entity names, types, and observation text — useful for finding entities when the exact name is uncertain.
6. Relations are directed (`from` → `to`) — querying a relation in the wrong direction will not return results; store both directions if bidirectional lookup is needed.
