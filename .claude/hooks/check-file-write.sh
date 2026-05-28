#!/usr/bin/env bash
# PreToolUse hook — blocks writes to system paths and path traversal sequences.
# Command hook (zero LLM cost) replacing the previous prompt hook.
# Intentionally permissive for project-local paths — bypassPermissions handles the rest.
set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

# Nothing to check
[ -z "$file_path" ] && exit 0

# Block path traversal
if [[ "$file_path" == *"../"* ]]; then
  jq -n --arg p "$file_path" '{
    hookSpecificOutput: {permissionDecision: "deny"},
    systemMessage: "block: path traversal (../) in file path: \($p)"
  }'
  exit 0
fi

# Block writes to system directories
if [[ "$file_path" =~ ^(/etc/|/usr/bin/|/usr/local/bin/|/bin/|/sbin/|/System/|/private/etc/) ]]; then
  jq -n --arg p "$file_path" '{
    hookSpecificOutput: {permissionDecision: "deny"},
    systemMessage: "block: write to system path denied: \($p). Use a project-local path instead."
  }'
  exit 0
fi

# Allow everything else
exit 0
