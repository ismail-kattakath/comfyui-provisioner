#!/bin/bash
set -euo pipefail

ENV_FILE="$CLAUDE_PROJECT_DIR/.env"
EXAMPLE_FILE="$CLAUDE_PROJECT_DIR/.env.example"

# Copy .env.example -> .env if .env doesn't exist
if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$EXAMPLE_FILE" ]; then
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    echo "Created .env from .env.example" >&2
  fi
fi

# Export variables into Claude's shell via CLAUDE_ENV_FILE
if [ -f "$ENV_FILE" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    # Only process KEY=VALUE lines
    [[ "$line" == *"="* ]] || continue
    echo "export $line" >> "$CLAUDE_ENV_FILE"
  done < "$ENV_FILE"
  # Bridge: GitHub MCP server reads GITHUB_PERSONAL_ACCESS_TOKEN inside its Docker container;
  # forward it from GITHUB_TOKEN so .env only needs one variable.
  printf '%s\n' '[ -n "${GITHUB_TOKEN:-}" ] && [ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && export GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_TOKEN"' >> "$CLAUDE_ENV_FILE"
fi
