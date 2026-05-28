#!/usr/bin/env bash
# enforce-delegation.sh — PreToolUse hook
#
# Enforces the "Delegation default" rule from CLAUDE.md:
#   Any task whose discovery phase requires more than 2 read-only
#   investigations MUST dispatch a background Explore (or general-purpose)
#   subagent. The 3rd+ read-only tool call in a session without an
#   intervening Agent dispatch is denied with a structured reason.
#
# Counter persists at: $CLAUDE_PROJECT_DIR/.claude/state/readonly-count.<session_id>
# Counter resets when this hook observes a tool call to `Agent`.
#
# Inputs (stdin, JSON):
#   { session_id, cwd, hook_event_name, tool_name, tool_input: {...} }
#
# Outputs (stdout, JSON):
#   - Deny (count >= 3 read-only without Agent reset):
#       {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#        "permissionDecision":"deny","permissionDecisionReason":"..."}}
#   - Otherwise: nothing (exit 0 = no decision; normal flow).
#
# Exit codes: 0 always (deny is signaled by JSON, not exit code).

set -euo pipefail

# Read full event into memory once.
EVENT="$(cat)"

# Best-effort field extraction. If jq fails on malformed input, exit 0 quietly.
TOOL_NAME="$(printf '%s' "$EVENT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$EVENT" | jq -r '.session_id // "nosession"' 2>/dev/null || echo nosession)"

# Sanitize session id for filename use.
SAFE_SESSION="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128)"

STATE_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/state"
COUNTER_FILE="$STATE_DIR/readonly-count.$SAFE_SESSION"

mkdir -p "$STATE_DIR"

# --- Counter reset on Agent dispatch ---
if [[ "$TOOL_NAME" == "Agent" ]]; then
  : > "$COUNTER_FILE"   # truncate
  exit 0
fi

# --- Classify whether this call counts as "read-only investigation" ---
is_readonly=0
case "$TOOL_NAME" in
  Read|Grep|Glob)
    is_readonly=1
    ;;
  Bash)
    CMD="$(printf '%s' "$EVENT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"
    # Strip leading whitespace then take first token (the actual command).
    FIRST_TOKEN="$(printf '%s' "$CMD" | sed -E 's/^[[:space:]]+//' | awk '{print $1}')"
    case "$FIRST_TOKEN" in
      jq|grep|wc|find|ls|cat|head|tail)
        is_readonly=1
        ;;
      git)
        SECOND_TOKEN="$(printf '%s' "$CMD" | sed -E 's/^[[:space:]]+//' | awk '{print $2}')"
        case "$SECOND_TOKEN" in
          log|status|diff|show) is_readonly=1 ;;
        esac
        ;;
    esac
    ;;
  mcp__*)
    # Read-only iff name does NOT contain any mutating verb.
    lower="$(printf '%s' "$TOOL_NAME" | tr '[:upper:]' '[:lower:]')"
    if ! printf '%s' "$lower" | grep -Eq 'write|create|update|delete|edit|push|send|start|stop'; then
      is_readonly=1
    fi
    ;;
esac

if [[ "$is_readonly" -ne 1 ]]; then
  exit 0
fi

# --- Increment + persist ---
COUNT=0
if [[ -f "$COUNTER_FILE" ]]; then
  COUNT="$(tr -cd '0-9' < "$COUNTER_FILE" 2>/dev/null || echo 0)"
  COUNT="${COUNT:-0}"
fi
COUNT=$((COUNT + 1))
printf '%s' "$COUNT" > "$COUNTER_FILE"

# --- Decide ---
if [[ "$COUNT" -ge 3 ]]; then
  REASON="Delegation default (CLAUDE.md): >2 read-only investigations in this session require dispatching a background Explore subagent. End the current turn and re-issue the work via Agent({run_in_background:true, subagent_type:'Explore', ...})."
  jq -nc --arg reason "$REASON" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

exit 0
