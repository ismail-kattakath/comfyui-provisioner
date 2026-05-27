---
name: duckduckgo
description: Search the web or news via DuckDuckGo when the user asks to look something up, find documentation, check for recent AI model releases, or research any topic without an API key
---

# DuckDuckGo MCP — 2 Tools Reference

Configured in `.mcp.json` as `"duckduckgo"` (stdio). No authentication required.

## MCP_DOCKER Priority

When the `MCP_DOCKER` server is available, prefer `mcp__MCP_DOCKER__brave_web_search` and `mcp__MCP_DOCKER__brave_news_search` over `mcp__duckduckgo__duckduckgo_search_text` and `mcp__duckduckgo__duckduckgo_search_news`. The local DuckDuckGo server is the fallback when MCP_DOCKER is unavailable or unauthenticated. Brave provides richer results including video and image search.

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|------------|
| General web search | `mcp__duckduckgo__duckduckgo_search_text` | `query`, `max_results`, `region`, `safesearch` |
| News / recent events | `mcp__duckduckgo__duckduckgo_search_news` | `query`, `max_results`, `region`, `safesearch` |

## Common Workflows

### 1. Search for a Library or Tool Documentation
```
mcp__duckduckgo__duckduckgo_search_text(
  query="ComfyUI custom nodes LTX-Video installation",
  max_results=5,
  region="us-en"
)
```
Then fetch the most relevant URL with the `fetch` MCP server or `mcp__MCP_DOCKER__fetch` for full content.

### 2. Search for Recent AI Model Releases
```
mcp__duckduckgo__duckduckgo_search_news(
  query="LTXV new model release 2025",
  max_results=10,
  region="us-en"
)
```

### 3. Check Current Documentation When Context7 Doesn't Have It
```
mcp__duckduckgo__duckduckgo_search_text(
  query="EasyFlow ComfyUI v1.7 changelog site:github.com",
  max_results=5
)
```
Use `site:` operator to scope results to authoritative sources.

## Configuration

No authentication required. Runs via `uvx duckduckgo-mcp-server` (stdio transport). No environment variables needed.

## Known Behaviors

1. Results include title, URL, and snippet only — they do not include full page content. Combine with `fetch` or `mcp__MCP_DOCKER__fetch` to retrieve full page text.
2. Rate limiting may apply for high-volume searches — add a brief pause between bulk queries if results start degrading.
3. The `region` param (e.g. `"us-en"`, `"wt-wt"` for worldwide) affects result locale and relevance ranking.
4. `safesearch` accepts `"on"`, `"moderate"`, or `"off"` — defaults to moderate if omitted.
5. DuckDuckGo does not offer image, video, or local place search — use `mcp__MCP_DOCKER__brave_image_search` or `mcp__MCP_DOCKER__brave_video_search` for those.
