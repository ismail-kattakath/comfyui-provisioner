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
fi
