#!/usr/bin/env bash
# PreToolUse hook — hard-denies built-in web tools and MCP_DOCKER web equivalents.
# Forces routing through local project MCP servers instead.
jq -n '{
  hookSpecificOutput: {permissionDecision: "deny"},
  systemMessage: "Use local project MCPs instead of built-in/MCP_DOCKER web tools:\n  fetch URL or webpage  →  mcp__fetch__fetch\n  web search            →  mcp__duckduckgo__duckduckgo_search_text\n  news search           →  mcp__duckduckgo__duckduckgo_search_news"
}'
