---
name: context7
description: Look up up-to-date library or package documentation — resolve a library name and fetch focused docs on a specific topic or API.
---

# Context7 — 2 Tools Reference

Configured in `.mcp.json` as `"context7"` (stdio, `npx -y @upstash/context7-mcp`). API key optional (free tier works without one; key raises rate limits).

> **MCP_DOCKER priority**: When the `MCP_DOCKER` server is available, prefer `mcp__MCP_DOCKER__resolve-library-id` and `mcp__MCP_DOCKER__get-library-docs` over `mcp__context7__resolve-library-id` and `mcp__context7__query-docs`.

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|-----------|
| Resolve a package name to a library ID | `resolve-library-id` | `libraryName` (string, required), `query` (string, required — your task/question, used to rank results) |
| Fetch focused library documentation | `query-docs` | `libraryId` (string, required — e.g. `/facebook/react`), `query` (string, required — your question or topic) |

## Common Workflows

### 1. Look Up React Docs on Hooks
```
resolve-library-id(libraryName="react", query="how to use hooks")
# Returns candidates with IDs, descriptions, trust scores — pick the best match

query-docs(libraryId="/facebook/react", query="useState and useEffect hooks")
```

### 2. Look Up Python Package Docs
```
resolve-library-id(libraryName="httpx", query="async HTTP client")

query-docs(libraryId="/encode/httpx", query="async client usage")
```

### 3. Resolve Ambiguous Package Name Then Fetch Docs
```
# Step 1: resolve — inspect trust scores and descriptions to pick the right entry
resolve-library-id(libraryName="transformer", query="text classification pipeline")

# Step 2: fetch with a narrow query to stay within token budget
query-docs(libraryId="/huggingface/transformers", query="pipeline for text classification")
```

## Configuration

```
CONTEXT7_API_KEY   — Optional. Free key at context7.com/dashboard for higher rate limits.
                     Automatically loaded from .env via SessionStart hook.
```

## Known Behaviors

1. `resolve-library-id` returns multiple candidates — always check trust scores and descriptions before passing the ID to `query-docs`; the first result is not always the intended library.
2. The `query` param in both tools is required and should describe your actual task — it's used to rank candidates and focus the documentation returned.
3. Library IDs are path-style strings (e.g. `"/facebook/react"`) — pass them verbatim; do not URL-encode or strip the leading slash.
4. Documentation is fetched live from Context7's index and reflects recent library versions, not training-data snapshots.
5. Without `CONTEXT7_API_KEY`, the free tier applies — works for normal usage but may rate-limit under heavy use.
