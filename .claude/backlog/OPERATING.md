# Backlog System — Lead Operating Notes

This document is the Lead's operational guide for the brainstorming backlog.
It is designed to survive context compaction — re-read on session start if unsure.

Full schema and lifecycle: `.claude/backlog/README.md`

---

## Session Start Checklist

1. Check `items.json` for `needs-approval` items → surface to user
2. Check `inbox.jsonl` for ungroomed lines → re-arm groomer if any
3. Check `ledger.json` for stale `in-progress` items (dispatched_at > 10 min ago) → clean up if subagent is done

---

## Keeping the Groomer Re-Armed

The `backlog-groomer` subagent is finite (runs once, outputs 1 line, stops).
The Lead must re-dispatch it after:
- Any `/idea` capture (new inbox line)
- Any item transitions to `done` or `avoided` (re-evaluates postponed deps)
- Session start (catch up on any accumulated inbox lines)

Dispatch pattern:
```
Agent({
  description: "Groom backlog",
  prompt: "Run a groom cycle on .claude/backlog/. Ingest inbox, refine items, set conflicts, score priority, mark gate:approval for paid/push/destructive ops. Output 1 line summary.",
  subagent_type: "backlog-groomer",
  model: "sonnet",
  run_in_background: True
})
```

---

## Stop-Hook Dispatch Flow (AUTOPILOT mode)

When `AUTOPILOT` flag is present, `backlog-dispatch.sh` fires at every turn end.

If it returns exit 2, the JSON reason string instructs the Lead:

```
AUTOPILOT: spawn ONE background Execution subagent for backlog item <id> '<refined>'.
BEFORE spawning: (1) add {...} to ledger.json running array; (2) set items.json item <id> status to in-progress.
Then dispatch the subagent with the full refined task text.
Conflict tags: <...>. After dispatching, end your turn immediately.
```

**Lead actions on receiving this instruction:**

1. Read `ledger.json`; add the specified entry to `running`; write back atomically
2. Read `items.json`; find item by id; set `status: "in-progress"`, add history entry; write back atomically
3. Dispatch ONE background executor:
   ```
   Agent({
     description: "Execute backlog item <id>",
     prompt: "<refined task text> — full self-contained instructions here",
     model: "sonnet",
     run_in_background: True
   })
   ```
4. End the turn immediately (do NOT do anything else)

---

## On Executor Completion

When a background executor finishes:

1. Remove the item from `ledger.json` running array
2. Set `items.json` item `status: "done"` (or `"avoided"` on failure), add history entry
3. Re-dispatch the groomer (postponed items may now be unblocked)
4. Check `needs-approval` items and surface to user if any

---

## Approval Gate

After each groom, check `items.json` for `status: "needs-approval"` items.
Surface them:
> "Item `<id[:8]>`: '<refined>' requires your approval before auto-dispatch (reason: paid/push/destructive).
> Say **approve `<id[:8]>`** to queue it, or **skip `<id[:8]>`** to avoid it."

On "approve <id>": set `status: "ready"`, `gate: "none"`, add history entry, re-groom.
On "skip <id>": set `status: "avoided"`, add history entry.

---

## Anti-Loop Guarantee

Even if the Lead fails to mark an item in-progress after a dispatch:
- **30s cooldown**: `.last-dispatch` timestamp; hook exits 0 if < 30s since last fire
- **Ledger cap**: if `running` count >= `MAX_CONCURRENT` (default 2), hook exits 0

Worst case with failed mark: one re-dispatch attempt per 30s, capped at MAX_CONCURRENT.
The system is bounded and cannot run away.

---

## Controls

```bash
# Autopilot (auto-dispatch ready items on turn end)
touch .claude/backlog/AUTOPILOT    # ON
rm .claude/backlog/AUTOPILOT       # OFF (default)

# Emergency pause (ALL hook activity no-ops)
touch .claude/backlog/PAUSED       # ON
rm .claude/backlog/PAUSED          # OFF

# Adjust concurrency cap
# Edit .claude/backlog/config.json: {"MAX_CONCURRENT": N, "QUIET_HOURS": null}
```

---

## Atomic Write Pattern

Always write `items.json` and `ledger.json` via temp+mv:
```bash
python3 -c "
import json, os
data = {...}  # modified data
with open('.claude/backlog/items.json.tmp', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
os.rename('.claude/backlog/items.json.tmp', '.claude/backlog/items.json')
"
```
