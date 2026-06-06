# Brainstorming Backlog System

A lightweight, agent-operated brainstorm-capture → groom → (optional) auto-dispatch pipeline.
Built for the comfyui-provisioner workspace. All state files live here in `.claude/backlog/`.

---

## Quick Reference

| Control | How |
|---------|-----|
| Capture an idea | `/idea <text>` — instant, ack in 1 line, never blocks |
| View the backlog | `/backlog` — grouped status view |
| Enable auto-dispatch | `touch .claude/backlog/AUTOPILOT` |
| Disable auto-dispatch | `rm .claude/backlog/AUTOPILOT` |
| Pause ALL hook activity | `touch .claude/backlog/PAUSED` |
| Resume | `rm .claude/backlog/PAUSED` |

---

## Files

### `inbox.jsonl`
**Append-only.** Each line is a raw capture written atomically by `/idea`.
Never manually edited. The groomer drains it into `items.json`.

Line schema:
```json
{"id":"<uuidv4>","raw":"<verbatim user text>","status":"raw","created_at":"<ISO-8601 UTC>"}
```

### `items.json`
**Canonical groomed backlog.** The groomer (`backlog-groomer` subagent) is the only writer.
Written atomically via temp-file + mv.

```json
{
  "items": [
    {
      "id": "uuid",
      "raw": "original capture text",
      "refined": "Clear imperative: do X to achieve Y",
      "status": "raw|groomed|ready|needs-approval|in-progress|done|postponed|avoided",
      "priority": {
        "score": 0,
        "why": "brief rationale (0=lowest, 100=highest)"
      },
      "conflicts": ["provisioner-config.sh", "vast:39718734", "stack-repo"],
      "deps": ["<other-item-id>"],
      "state_note": "Comparison to live state — e.g. 'file not yet committed', 'instance already running'",
      "gate": "none|approval",
      "created_at": "ISO-8601",
      "updated_at": "ISO-8601",
      "history": [
        {"at":"ISO-8601","from_status":"raw","to_status":"groomed","note":"..."}
      ]
    }
  ]
}
```

**Status lifecycle:**
```
raw → groomed → ready → in-progress → done
                      ↘ needs-approval → (user approves) → ready
                                       → (user rejects) → avoided
          groomed → postponed  (deps not met)
```

### `ledger.json`
Tracks which item IDs have a background executor currently in flight.
Updated by the **main lead agent** (not by hooks).

```json
{
  "running": [
    {
      "id": "item-uuid",
      "conflicts": ["resource-tag"],
      "dispatched_at": "ISO-8601"
    }
  ]
}
```

### `config.json`
```json
{"MAX_CONCURRENT":2,"QUIET_HOURS":null}
```
- `MAX_CONCURRENT`: max simultaneous background executors (default 2).
- `QUIET_HOURS`: future use — e.g. `{"start":"22:00","end":"08:00","tz":"America/New_York"}`.

### Control Flags (presence = ON)

| Flag file | Effect |
|-----------|--------|
| `AUTOPILOT` | Stop hook dispatches ready items automatically |
| `PAUSED` | ALL hook activity is a no-op — safe kill-switch |

---

## Item Schema Details

### `status` values

| Status | Meaning |
|--------|---------|
| `raw` | Just captured; not yet groomed |
| `groomed` | Refined + scored; deps/conflicts set; but deps not yet met |
| `ready` | Safe to execute; deps met; gate=none |
| `needs-approval` | Requires user confirmation before dispatch (paid/destructive/push ops) |
| `in-progress` | Background executor is running |
| `done` | Completed; also auto-set if state shows already done |
| `postponed` | Deps not met; re-evaluated each groom cycle |
| `avoided` | User rejected or explicitly skipped |

### `gate` values

| Gate | Trigger condition |
|------|-------------------|
| `none` | Default; safe to auto-dispatch |
| `approval` | Always set for: vast.ai rent/destroy, `git push`, irreversible/destructive ops |

### `conflicts` tags (examples)

Tags are strings describing which resources an item would mutate. The dispatcher checks for
intersection between running items' conflict sets and candidate items.

| Tag pattern | Meaning |
|-------------|---------|
| `provisioner-config.sh` | Edits the provisioner config |
| `stack-repo` | Edits a stack repo |
| `vast:<id>` | Operating on a specific VastAI instance |
| `git:push` | Will push to remote |
| `backlog` | Modifies backlog state itself |

---

## Lifecycle: How the Main Lead Operates This System

This section is written so it survives context compaction.

### 1. Capture
User types `/idea <text>`. The command appends one JSON line to `inbox.jsonl` and acks.
No grooming, no analysis, no blocking.

### 2. Grooming (background, continuous)
The `backlog-groomer` subagent is dispatched by the Lead after any session start or after
new items appear in inbox. It:
- Ingests `inbox.jsonl` lines not yet in `items.json`
- Refines text, sets conflicts, scores priority, checks deps
- Marks `gate:approval` for paid/push/destructive ops
- Writes `items.json` atomically
- Outputs a 1-line summary

**Re-arming:** The Lead re-dispatches the groomer after any new `/idea` capture or
after any item transitions to `done`/`avoided` (to re-evaluate postponed items).
This is the self-re-arming pattern.

### 3. Approval Gate
After each groom, the Lead checks `items.json` for `status:needs-approval` items and
surfaces them to the user: "Item <id>: '<refined>' requires your approval. Say 'approve <id>'
or 'skip <id>'."

On approval: set `status:ready`, `gate:none`. On skip: set `status:avoided`.

### 4. Auto-Dispatch (AUTOPILOT mode only)
When `AUTOPILOT` flag is present, the `backlog-dispatch.sh` Stop hook fires at each turn end.
It picks the highest-priority `ready` item with `gate:none` whose conflicts don't intersect
any running item's conflicts.

It emits a `block` decision (exit 2) instructing the Lead:
> "AUTOPILOT: spawn ONE background Execution subagent for item <id> '<refined>'.
>  First mark it in-progress in ledger.json + items.json. Conflict tags: <...>. Then end your turn."

The Lead must:
1. Update `ledger.json` → add the item to `running`
2. Update `items.json` → set item `status:in-progress`
3. Dispatch the background executor subagent
4. End the turn

### 5. Completion
When an executor finishes, the Lead:
1. Removes the item from `ledger.json` running array
2. Sets `items.json` item `status:done` (or `avoided` on failure)
3. Re-dispatches the groomer (to re-evaluate postponed items)
4. Checks for next `needs-approval` items to surface

### Anti-Loop Guarantee
Even if the Lead fails to mark an item `in-progress`, the dispatch hook has two backstops:
- **30-second cooldown** (`.last-dispatch` timestamp): the hook exits 0 if fired within 30s
- **Ledger cap**: if `ledger.running` count >= `MAX_CONCURRENT`, hook exits 0

These two together mean worst-case: one spurious dispatch per 30 seconds, bounded by MAX_CONCURRENT.

---

## Enabling / Disabling

```bash
# Enable auto-dispatch
touch .claude/backlog/AUTOPILOT

# Disable auto-dispatch (interactive mode)
rm .claude/backlog/AUTOPILOT

# Emergency pause — stops ALL hook activity
touch .claude/backlog/PAUSED

# Resume
rm .claude/backlog/PAUSED
```
