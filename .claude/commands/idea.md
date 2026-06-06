# /idea — Instant Idea Capture

Capture a brainstorm item instantly. One-line ack, no analysis, no waiting.
Grooming happens asynchronously via the `backlog-groomer` subagent.

## Usage

```
/idea <text>
```

## What this command does

1. Appends exactly ONE JSON line to `.claude/backlog/inbox.jsonl` using the one-liner below
2. Replies with exactly: `Captured ✓ — <≤8-word gist>`
3. STOPS. Does NOT analyze, groom, execute, or ask follow-up questions.

## Capture one-liner

Run this bash command to append the capture (replace `$RAW_TEXT` with the argument text):

```bash
python3 -c "
import json, sys, uuid, datetime
raw = sys.argv[1]
line = json.dumps({
    'id': str(uuid.uuid4()),
    'raw': raw,
    'status': 'raw',
    'created_at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
})
with open('.claude/backlog/inbox.jsonl', 'a') as f:
    f.write(line + '\n')
print('ok')
" "$RAW_TEXT"
```

The `json.dumps` call handles all escaping (quotes, backslashes, unicode) safely.
The file open in append mode (`'a'`) is race-free for single-line appends on Linux.

## What NOT to do

- Do NOT groom, refine, score, or categorize the item
- Do NOT check existing items for duplicates
- Do NOT ask clarifying questions
- Do NOT spawn agents
- Do NOT run preflight or any expensive check

## Ack format

```
Captured ✓ — <≤8-word gist of the raw text>
```

The gist is the only "thinking" allowed — a very short label so the user can confirm
the right thing was captured.

## Example

User: `/idea add a RunPod spot-pricing fallback when VastAI has no GPUs`

Steps:
1. Run the append one-liner with the full text as `$RAW_TEXT`
2. Reply: `Captured ✓ — RunPod fallback when VastAI has no GPUs`
