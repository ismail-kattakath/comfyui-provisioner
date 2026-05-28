#!/usr/bin/env bash
# PreToolUse hook — blocks Agent() calls that omit run_in_background: true.
# Command hook (zero LLM cost) replacing the previous prompt hook.
set -euo pipefail

input=$(cat)
run_in_bg=$(echo "$input" | jq -r '.tool_input.run_in_background // false')

if [ "$run_in_bg" != "true" ]; then
  jq -n '{
    hookSpecificOutput: {permissionDecision: "deny"},
    systemMessage: "block: all Agent calls must include run_in_background: true — the Lead must never block waiting for a subagent. Set run_in_background: true and retry."
  }'
  exit 0
fi

# run_in_background: true — allow
exit 0
