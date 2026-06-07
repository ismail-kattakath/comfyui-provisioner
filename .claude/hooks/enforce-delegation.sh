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

# --- Subagent exemption -------------------------------------------------------
# The delegation rule constrains the LEAD only. Subagents ARE the delegation
# target: they cannot spawn further subagents, so denying their 3rd read-only
# call deadlocks them (they hit the "go dispatch a subagent" wall with no way to
# comply, then confabulate). Exempt any session that is not the lead.
#
# A subagent's PreToolUse stdin .session_id differs from the lead's session id.
# We detect the lead two independent ways:
#   1. A marker file written at SessionStart (authoritative; refreshed per lead
#      session) — see the SessionStart hook in settings.json.
#   2. The CLAUDE_CODE_SESSION_ID env var, which carries the lead's id even into
#      subagent hook processes (belt-and-suspenders when the marker is absent).
# For the lead, stdin .session_id == marker == $CLAUDE_CODE_SESSION_ID, so the
# lead is never exempted; only non-lead (subagent) sessions are.
LEAD_FILE="$STATE_DIR/lead-session-id"
LEAD_SESSION=""
[[ -f "$LEAD_FILE" ]] && LEAD_SESSION="$(tr -d '[:space:]' < "$LEAD_FILE" 2>/dev/null || true)"
ENV_SESSION="${CLAUDE_CODE_SESSION_ID:-}"

if [[ -n "$LEAD_SESSION" && -n "$SESSION_ID" && "$SESSION_ID" != "$LEAD_SESSION" ]]; then
  exit 0   # subagent (differs from recorded lead) — exempt
fi
if [[ -n "$ENV_SESSION" && -n "$SESSION_ID" && "$SESSION_ID" != "$ENV_SESSION" ]]; then
  exit 0   # subagent (differs from lead env id) — exempt
fi

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
      # NOTE: `git status|diff|log|show` are intentionally NOT counted.
      # They are operational (commit ceremony, "what changed", etc.), not
      # codebase exploration — the rule targets discovery, not git introspection.
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
if [[ "$COUNT" -eq 3 ]]; then
  # Advisory ONLY — NEVER deny. A hard deny deadlocks subagents: they are the
  # delegation TARGET and cannot dispatch further subagents to reset the counter,
  # so on their 3rd read-only call they hit an un-satisfiable wall and confabulate.
  # The deny also false-blocked the lead on legitimate operational reads (judging
  # synced renders, editing config). Emit a single non-blocking nudge at the
  # threshold and always allow the call. (Was: permissionDecision=deny — removed
  # 2026-06-07 after it killed a subagent mid-task for the 2nd time.)
  MSG="Advisory (CLAUDE.md Delegation default): >2 read-only investigations this session. For discovery-heavy work prefer a background Explore subagent. Not blocking."
  jq -nc --arg m "$MSG" '{systemMessage:$m}'
fi

exit 0
