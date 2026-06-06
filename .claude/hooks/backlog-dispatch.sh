#!/usr/bin/env bash
# backlog-dispatch.sh — Stop hook for the brainstorming backlog system.
#
# Called by Claude Code on every main-agent turn end.
# SAFETY CONTRACT:
#   - Exit 0  → no-op; Claude continues normally.
#   - Exit 2  → block; JSON {"decision":"block","reason":"..."} tells the Lead what to do.
# This hook NEVER spawns agents, NEVER modifies ledger/items state.
# The Lead is responsible for marking items in-progress (which removes them from ready,
# breaking the re-dispatch cycle). Two independent backstops prevent infinite loops even
# if the Lead fails to mark in-progress:
#   1. 30-second cooldown via .last-dispatch timestamp
#   2. Ledger cap: if running >= MAX_CONCURRENT, exit 0
#
# Called as: echo '<stop-hook-json>' | bash backlog-dispatch.sh
# (Claude Code passes stop-hook context on stdin; we ignore it — all state is in files.)

set -euo pipefail

BACKLOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/backlog"

# ── Guard: PAUSED flag ───────────────────────────────────────────────────────
if [ -f "$BACKLOG_DIR/PAUSED" ]; then
  exit 0
fi

# ── Guard: AUTOPILOT flag ────────────────────────────────────────────────────
# Auto-dispatch is OFF by default. Only operates when user has explicitly opted in.
if [ ! -f "$BACKLOG_DIR/AUTOPILOT" ]; then
  exit 0
fi

# ── Guard: required files exist ─────────────────────────────────────────────
for f in items.json ledger.json config.json; do
  if [ ! -f "$BACKLOG_DIR/$f" ]; then
    exit 0  # System not initialized; be silent
  fi
done

# ── Guard: cooldown (30 seconds) ────────────────────────────────────────────
# Prevents re-firing if the Lead failed to mark the item in-progress.
LAST_DISPATCH="$BACKLOG_DIR/.last-dispatch"
if [ -f "$LAST_DISPATCH" ]; then
  last_ts=$(cat "$LAST_DISPATCH" 2>/dev/null || echo "0")
  now_ts=$(date +%s)
  if [ $(( now_ts - last_ts )) -lt 30 ]; then
    exit 0
  fi
fi

# ── Read config ──────────────────────────────────────────────────────────────
MAX_CONCURRENT=$(python3 -c "
import json, sys
try:
  cfg = json.load(open('$BACKLOG_DIR/config.json'))
  print(cfg.get('MAX_CONCURRENT', 2))
except Exception:
  print(2)
")

# ── Guard: QUIET_HOURS ───────────────────────────────────────────────────────
# Basic quiet-hours check (future: extend for timezone support)
QUIET_HOURS=$(python3 -c "
import json, sys
try:
  cfg = json.load(open('$BACKLOG_DIR/config.json'))
  qh = cfg.get('QUIET_HOURS')
  if qh is None:
    print('none')
  else:
    print(json.dumps(qh))
except Exception:
  print('none')
")

if [ "$QUIET_HOURS" != "none" ] && [ "$QUIET_HOURS" != "null" ]; then
  # QUIET_HOURS is set — parse start/end and check current hour
  in_quiet=$(python3 -c "
import json, datetime, sys
try:
  qh = json.loads('$QUIET_HOURS')
  if not qh:
    print('no')
    sys.exit(0)
  tz_name = qh.get('tz', 'UTC')
  try:
    import zoneinfo
    tz = zoneinfo.ZoneInfo(tz_name)
  except Exception:
    tz = datetime.timezone.utc
  now = datetime.datetime.now(tz)
  start_h, start_m = map(int, qh['start'].split(':'))
  end_h, end_m = map(int, qh['end'].split(':'))
  cur = now.hour * 60 + now.minute
  start = start_h * 60 + start_m
  end = end_h * 60 + end_m
  if start <= end:
    in_q = start <= cur < end
  else:
    in_q = cur >= start or cur < end
  print('yes' if in_q else 'no')
except Exception:
  print('no')
" 2>/dev/null || echo "no")
  if [ "$in_quiet" = "yes" ]; then
    exit 0
  fi
fi

# ── Guard: concurrency cap ───────────────────────────────────────────────────
RUNNING_COUNT=$(python3 -c "
import json, sys
try:
  ledger = json.load(open('$BACKLOG_DIR/ledger.json'))
  print(len(ledger.get('running', [])))
except Exception:
  print(0)
")

if [ "$RUNNING_COUNT" -ge "$MAX_CONCURRENT" ]; then
  exit 0
fi

# ── Collect conflict tags of currently running items ─────────────────────────
RUNNING_CONFLICTS=$(python3 -c "
import json, sys
try:
  ledger = json.load(open('$BACKLOG_DIR/ledger.json'))
  tags = set()
  for r in ledger.get('running', []):
    for c in r.get('conflicts', []):
      tags.add(c)
  print(json.dumps(list(tags)))
except Exception:
  print('[]')
")

# ── Pick best candidate ───────────────────────────────────────────────────────
# Highest-priority item where:
#   status == ready
#   gate   != approval
#   conflicts don't intersect running conflicts
CANDIDATE=$(python3 -c "
import json, sys

try:
  items_data = json.load(open('$BACKLOG_DIR/items.json'))
  running_conflicts = set(json.loads('$RUNNING_CONFLICTS'))

  candidates = [
    it for it in items_data.get('items', [])
    if it.get('status') == 'ready'
    and it.get('gate', 'none') != 'approval'
    and not (set(it.get('conflicts', [])) & running_conflicts)
  ]

  if not candidates:
    print('')
    sys.exit(0)

  # Sort by priority score descending, then created_at ascending (FIFO tiebreak)
  candidates.sort(key=lambda x: (
    -x.get('priority', {}).get('score', 0),
    x.get('created_at', '')
  ))

  best = candidates[0]
  print(json.dumps({
    'id': best['id'],
    'refined': best.get('refined', best.get('raw', '')),
    'conflicts': best.get('conflicts', []),
    'priority': best.get('priority', {}).get('score', 0)
  }))
except Exception as e:
  print('')
" 2>/dev/null || echo "")

# ── No candidate: exit cleanly ───────────────────────────────────────────────
if [ -z "$CANDIDATE" ] || [ "$CANDIDATE" = "null" ]; then
  exit 0
fi

# ── Extract candidate fields ─────────────────────────────────────────────────
ITEM_ID=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['id'])" "$CANDIDATE")
ITEM_REFINED=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['refined'])" "$CANDIDATE")
ITEM_CONFLICTS=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(', '.join(d['conflicts']) or 'none')" "$CANDIDATE")

# ── Write cooldown timestamp ──────────────────────────────────────────────────
# Do this BEFORE emitting the block, so if the Lead processes the block and
# the hook re-fires in the same second, the cooldown is already in place.
date +%s > "$LAST_DISPATCH"

# ── Emit block decision ───────────────────────────────────────────────────────
# Exit 2 with JSON reason instructs the Lead to act.
# The Lead must:
#   1. Update ledger.json (add item to running)
#   2. Update items.json (set status=in-progress)
#   3. Dispatch ONE background executor subagent
#   4. End its turn
#
# The reason string is the instruction to the Lead — it appears as a system
# message in the next turn.

REASON="AUTOPILOT: spawn ONE background Execution subagent for backlog item ${ITEM_ID} '${ITEM_REFINED}'. BEFORE spawning: (1) add {\"id\":\"${ITEM_ID}\",\"conflicts\":[$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(','.join(json.dumps(c) for c in d['conflicts']))" "$CANDIDATE")],\"dispatched_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"} to ledger.json running array; (2) set items.json item ${ITEM_ID} status to in-progress. Then dispatch the subagent with the full refined task text. Conflict tags: ${ITEM_CONFLICTS}. After dispatching, end your turn immediately."

python3 -c "
import json, sys
reason = sys.argv[1]
print(json.dumps({'decision': 'block', 'reason': reason}))
" "$REASON"

exit 2
