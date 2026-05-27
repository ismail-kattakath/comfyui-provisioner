#!/usr/bin/env bash
# UserPromptSubmit hook — injects tool routing rules as a systemMessage on every turn.
# Keeps routing fresh even after context compaction. Local MCPs override MCP_DOCKER.
jq -n '{
  systemMessage: (
    "TOOL ROUTING — local project MCPs override MCP_DOCKER equivalents:\n" +
    "• terminal / shell / files / processes  →  mcp__desktop-commander__*\n" +
    "• fetch URL or webpage                  →  mcp__fetch__fetch\n" +
    "• library / API documentation           →  mcp__context7__resolve-library-id  then  mcp__context7__query-docs\n" +
    "• web search / news                     →  mcp__duckduckgo__duckduckgo_search_text  /  _search_news\n" +
    "• JSON query / filter                   →  mcp__mcp-jq__*\n" +
    "• JSON / YAML / TOML read-edit          →  mcp__json-yaml-toml__*\n" +
    "• file diffs                            →  mcp__diff__*\n" +
    "• GitHub operations                     →  mcp__github__*\n" +
    "• HuggingFace search / metadata / docs  →  mcp__huggingface__*\n" +
    "• HuggingFace Space logs (runtime/build)→  curl -sN --max-time <sec> with source .env (see hf-space-logs skill)\n" +
    "• Civitai models / images               →  mcp__civitai__*\n" +
    "• Docker Hub                            →  mcp__dockerhub__*\n" +
    "• Vast.ai GPU instances                 →  mcp__vast-ai__*\n" +
    "• remember / recall across turns        →  mcp__memory__*  (search_nodes to recall; create_entities / add_observations to store)\n" +
    "• complex / multi-step task             →  mcp__sequentialthinking__sequentialthinking  first\n" +
    "Never use: Bash(curl/wget), WebFetch, WebSearch, mcp__MCP_DOCKER__fetch__*, or mcp__MCP_DOCKER__brave__* for any of the above."
  )
}'
