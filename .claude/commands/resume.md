---
description: >
  Resume a long-running investigation from a committed handoff note in
  .claude/handoffs/. Loads the topic file into context and primes the session
  with what's already been done, what's open, and operating constraints.
argument-hint: <topic-slug>  (e.g. iclight-v2v-quality)
allowed-tools: Read, Bash
---

# /resume

The reusable session-resume primitive. Long investigations frequently cross
context-compaction or session boundaries; without a handoff, the next
session rebuilds context from scratch — re-reads commits, re-derives state,
sometimes re-debugs already-fixed bugs. Handoff notes turn that into a
one-command pickup.

Works identically on host and inside the devcontainer because the handoff
path is project-root-relative.

## Usage

```
/resume <topic-slug>
```

**Example:**
```
/resume iclight-v2v-quality
```

## What it does

1. Parses `$ARGUMENTS` — first token is `TOPIC_SLUG` (required).
2. Reads `.claude/handoffs/<TOPIC_SLUG>.md` (path is relative to the
   provisioner repo root, which is `git rev-parse --show-toplevel`).
3. If the file is missing: lists available slugs (`ls .claude/handoffs/`) and
   asks the user which one they meant — does NOT guess.
4. Prints the handoff content into the session so it becomes ambient context
   for follow-up turns.
5. Restates the operating constraints from the handoff (especially anything
   marked **constraint** / **safety** / "do NOT re-debug").

## What it does NOT do

- Take any action the handoff describes. Reading the handoff is context-
  loading, not execution. The user drives the next step.
- Modify the handoff file. Updates happen explicitly when the user says "add
  to the handoff" or after a session naturally ends.
- Assume what stack the handoff refers to. If the handoff names a `STACK_REPO`,
  surface it; if not, ask the user before acting on anything stack-specific.

## Handoff file format (convention, not enforced)

Any markdown is fine, but the most useful handoffs have these sections:

- **Status** — when the handoff was written, what state things were in
- **Do NOT re-debug** — fixed bugs with commit refs, so the next session
  doesn't re-derive them
- **Open / current focus** — the actual unresolved problem
- **Hypotheses / suggested next moves** — ranked
- **Constraints** — paid services, edit conventions, safety gates
- **Last instance / artifact references** — IDs that may still be live

## Producing new handoffs

When the user says "crystallize this session" / "write a handoff" / "save
state for next session":

1. Write `.claude/handoffs/<descriptive-topic-slug>.md`.
2. Commit it: `chore(handoffs): <topic> handoff`.
3. Give the user the trigger prompt: `/resume <topic-slug>`.

Slugs should be kebab-case, descriptive of the investigation (not the date):
- ✅ `iclight-v2v-quality`
- ✅ `vastai-oom-debugging`
- ❌ `session-2026-06-06`
- ❌ `handoff`

## Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `no such handoff: <slug>` | typo or never written | `ls .claude/handoffs/` to see available |
| Handoff content seems stale | written days ago, codebase moved | verify referenced files/commits still exist before acting on recommendations |
| Multiple handoffs reference each other | crossover investigations | read them in `[[link]]` order; resume the most current one and let it pull others in |
