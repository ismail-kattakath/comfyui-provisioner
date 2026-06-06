# /backlog — View the Brainstorming Backlog

Pretty-print the current backlog grouped by status. Shows priority, gist, and conflict tags.
Also shows AUTOPILOT and PAUSED state.

## Usage

```
/backlog
```

## What this command does

1. Reads `.claude/backlog/items.json`, `ledger.json`, `config.json`
2. Checks for `AUTOPILOT` and `PAUSED` flag files
3. Outputs a formatted view grouped by status

This command is READ-ONLY. It does not modify any state.

## Display format

Run this to produce the backlog view:

```bash
python3 -c "
import json, os, datetime

BACKLOG = '.claude/backlog'

# Control flags
autopilot = os.path.exists(f'{BACKLOG}/AUTOPILOT')
paused = os.path.exists(f'{BACKLOG}/PAUSED')

# Load data
try:
    items = json.load(open(f'{BACKLOG}/items.json')).get('items', [])
except Exception:
    items = []

try:
    ledger = json.load(open(f'{BACKLOG}/ledger.json'))
    running_ids = {r['id'] for r in ledger.get('running', [])}
except Exception:
    running_ids = set()

try:
    cfg = json.load(open(f'{BACKLOG}/config.json'))
    max_concurrent = cfg.get('MAX_CONCURRENT', 2)
except Exception:
    max_concurrent = 2

# Header
print('=== BACKLOG ===')
mode = []
if paused:
    mode.append('PAUSED (all hooks no-op)')
elif autopilot:
    mode.append('AUTOPILOT ON')
else:
    mode.append('autopilot OFF (interactive)')
print(f'Mode: {\" | \".join(mode)}')
print(f'Concurrency: {len(running_ids)}/{max_concurrent} running')
print()

# Group by status
STATUS_ORDER = ['in-progress', 'ready', 'needs-approval', 'groomed', 'raw', 'postponed', 'done', 'avoided']
STATUS_LABELS = {
    'in-progress': '▶ IN PROGRESS',
    'ready':       '✓ READY',
    'needs-approval': '⚠ NEEDS APPROVAL',
    'groomed':     '~ GROOMED (deps pending)',
    'raw':         '· RAW',
    'postponed':   '⏸ POSTPONED',
    'done':        '✔ DONE',
    'avoided':     '✗ AVOIDED',
}

by_status = {}
for it in items:
    s = it.get('status', 'raw')
    by_status.setdefault(s, []).append(it)

total = len(items)
shown = 0
for status in STATUS_ORDER:
    group = by_status.get(status, [])
    if not group:
        continue
    label = STATUS_LABELS.get(status, status.upper())
    print(f'{label} ({len(group)})')
    group_sorted = sorted(group, key=lambda x: -x.get('priority', {}).get('score', 0))
    for it in group_sorted:
        score = it.get('priority', {}).get('score', '?')
        refined = it.get('refined') or it.get('raw', '')
        # Truncate long refined text
        if len(refined) > 80:
            refined = refined[:77] + '...'
        conflicts = it.get('conflicts', [])
        conf_str = ' [' + ', '.join(conflicts) + ']' if conflicts else ''
        gate = it.get('gate', 'none')
        gate_str = ' [GATE:approval]' if gate == 'approval' else ''
        iid = it['id'][:8]
        deps = it.get('deps', [])
        dep_str = f' deps:{len(deps)}' if deps else ''
        print(f'  [{iid}] p={score:>3}  {refined}{conf_str}{gate_str}{dep_str}')
    shown += len(group)
    print()

if total == 0:
    print('  (empty — use /idea to capture items)')

print(f'Total: {total} items')
"
```

## Controls reminder

```
touch .claude/backlog/AUTOPILOT   # enable auto-dispatch
rm .claude/backlog/AUTOPILOT      # disable auto-dispatch
touch .claude/backlog/PAUSED      # pause all hooks
rm .claude/backlog/PAUSED         # resume
```

To approve a needs-approval item:
- Tell the Lead: "approve <8-char-id-prefix>" and the Lead will set status=ready, gate=none.

To skip/avoid an item:
- Tell the Lead: "skip <8-char-id-prefix>" and the Lead will set status=avoided.
