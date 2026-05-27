---
name: fetch-mcp
description: Fetch full content of a URL, read documentation pages, call API endpoints, or paginate through long web content when the user provides a URL to retrieve
---

# Fetch MCP — 1 Tool Reference

Configured in `.mcp.json` as `"fetch"` (stdio). No authentication required.

## MCP_DOCKER Priority

When the `MCP_DOCKER` server is available, prefer `mcp__MCP_DOCKER__fetch` over `mcp__fetch__fetch`. The local fetch server is the fallback when MCP_DOCKER is unavailable or unauthenticated. Both tools share the same interface and behavior.

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|------------|
| Fetch a web page as markdown | `mcp__fetch__fetch` | `url`, `max_length` |
| Fetch raw HTML | `mcp__fetch__fetch` | `url`, `raw: true` |
| Call an API endpoint | `mcp__fetch__fetch` | `url`, `method`, `headers`, `body` |
| Paginate through long content | `mcp__fetch__fetch` | `url`, `start_index`, `max_length` |

## Common Workflows

### 1. Fetch a Documentation Page Found via Search
```
mcp__fetch__fetch(
  url="https://docs.comfy.org/essentials/custom_node_overview",
  max_length=10000
)
```
Increase `max_length` beyond the default 5000 to retrieve more content in one call.

### 2. Call an API Endpoint (GET with Auth Header)
```
mcp__fetch__fetch(
  url="https://civitai.com/api/v1/models/12345",
  method="GET",
  headers={"Authorization": "Bearer YOUR_TOKEN", "Content-Type": "application/json"}
)
```

### 3. POST to an API Endpoint
```
mcp__fetch__fetch(
  url="https://api.example.com/generate",
  method="POST",
  headers={"Content-Type": "application/json"},
  body="{\"prompt\": \"a cat\", \"steps\": 20}"
)
```

### 4. Paginate Through a Long Page
```
# First chunk
mcp__fetch__fetch(url="https://example.com/long-doc", max_length=5000, start_index=0)

# Second chunk
mcp__fetch__fetch(url="https://example.com/long-doc", max_length=5000, start_index=5000)
```
Repeat with incrementing `start_index` until content is fully retrieved.

### 5. Retrieve Raw HTML When Markdown Conversion Loses Structure
```
mcp__fetch__fetch(
  url="https://example.com/page-with-complex-table",
  raw=true,
  max_length=20000
)
```

## Configuration

No authentication required. Runs via `npx -y @modelcontextprotocol/server-fetch` (stdio transport). No environment variables needed.

## Known Behaviors

1. Default output is markdown-converted content — better for LLM consumption; tables and code blocks are preserved in most cases.
2. `max_length` defaults to 5000 characters and truncates output — increase it (e.g. 20000–50000) for full documentation pages.
3. Use `start_index` to retrieve subsequent chunks of content that exceeds `max_length`; combine multiple calls to reconstruct a full page.
4. `raw: true` returns raw HTML — useful when the markdown converter drops structure (nested tables, complex layouts, embedded code).
5. JavaScript-rendered pages (SPAs like React/Vue apps) may return incomplete or empty content — for those, use `mcp__MCP_DOCKER__playwright__*` browser tools instead.
6. The tool follows HTTP redirects automatically; final URL after redirect is the content source.
7. Pair with `duckduckgo_search_text` or `mcp__MCP_DOCKER__brave_web_search` to find URLs, then fetch full content with this tool.
