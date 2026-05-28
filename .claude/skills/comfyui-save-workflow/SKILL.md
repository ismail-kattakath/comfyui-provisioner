---
name: comfyui-save-workflow
description: Push a ComfyUI workflow edit from a running VastAI instance back to its canonical stack repo on GitHub. Use when the user asks to "push the workflow", "save workflow to git", "commit my workflow", "sync workflow back", or says "I'm done with workflow X". Wraps the /workspace/save-workflow.sh helper that ships with ismail-kattakath/comfyui-provisioner.
---

# comfyui-save-workflow

Orchestrates pushing a Cmd+S'd ComfyUI workflow back to its source stack repo
on GitHub. The heavy lifting (git identity, fetch + rebase, commit, push,
conflict surfacing) is done by the `/workspace/save-workflow.sh` helper that
the framework drops on every instance at boot. This skill just wraps the SSH
call + result reporting.

## When to invoke

Trigger phrases (case-insensitive, partial match counts):
- "push the workflow"
- "save (the )?workflow to git"
- "commit (my )?workflow"
- "sync workflow (back)?"
- "I'm done with workflow <name>"

If the user's request is ambiguous (multiple workflows, no clear target), ask
before executing — this is intentionally explicit, not auto-on-Cmd+S.

## Required context

| Field | Source |
|---|---|
| Active instance ID | `vastai show instances` (pick `running`) — if multiple, ask which |
| SSH endpoint | `vastai ssh-url <id>` returns `ssh://root@<ip>:<port>` — always use direct IP, never the proxied `ssh*.vast.ai` address |
| Workflow filename | If user didn't name one, list with `bash /workspace/save-workflow.sh --list` and ask |
| Target branch | Default `main`. Ask if they want a feature branch (e.g. `iteration/v2`) before pushing experimental edits to `main`. |

## Execution

The single command this skill runs on the remote:

```bash
ssh -i ~/.ssh/id_ed25519 -p <port> root@<ip> \
  'bash /workspace/save-workflow.sh <name.json> [branch]'
```

The helper takes care of:
1. Pre-flight check for stale `.git/rebase-merge` from a previous failed run
2. Persisting git identity into the stack repo's config
3. Switching to the requested branch (creates if it doesn't exist)
4. `git fetch + rebase` on `origin/<branch>` before the commit (skip with
   `-e AUTO_REBASE=0` only for users with long-lived branch workflows)
5. Copying the live workflow file → stack repo's `comfyui/` dir
6. `git add`, no-op exit if nothing changed
7. `git commit -m "Update <workflow> from ComfyUI on <hostname>"`
8. `git push origin <branch>`
9. Printing the resulting commit SHA + `https://github.com/<owner>/<repo>/commit/<sha>` URL

## Reporting back

| Helper output | What to say to the user |
|---|---|
| `✓ commit: <sha>` + view URL | Pass through. Say "Pushed as `<sha>` → `<url>`". |
| `no changes vs <branch> — nothing to commit` | "No diff vs current `<branch>` — your local copy is already in sync." |
| `REBASE FAILED with conflicts` + recovery commands | Surface the helper's recovery commands verbatim. Ask the user whether to resolve manually or abort the rebase. Don't auto-resolve. |
| `PUSH FAILED after rebase` | Suggest re-running (often a transient race). If it persists twice, dig in. |
| `WARNING: a previous rebase is unfinished` | Show the user the four recovery commands the helper printed. Ask which they want. Don't auto-`rm -rf .git/rebase-merge`. |
| Missing `/workspace/.provisioner.env` | Instance wasn't provisioned by `ismail-kattakath/comfyui-provisioner`. Surface that. Don't attempt to push. |

## Don't do these things

- **Don't auto-push without confirming the workflow + branch with the user.**
  The whole point of the helper is explicit-not-magic.
- **Don't bypass `save-workflow.sh`** by SSHing in and running `git` commands
  directly. The helper handles edge cases (identity, rebase state, stale
  refs) that ad-hoc git commands miss.
- **Don't commit `STACK_REPO` / `STACK_DIR` paths to the conversation** if
  the stack is private — assume privacy by default unless the user has
  shared the repo name with the wider context already.
- **Don't suggest auto-on-Cmd+S** — the user explicitly chose the explicit
  flow over the auto-push extension when this was designed (commit
  `5333924`). Match that preference.

## Failure recovery (manual reference)

If the helper bails partway and the user is stuck, the typical recovery is:

```bash
ssh ... bash -c '
  cd /workspace/<stack-dir-name>
  git status                              # see what state we are in
  git rebase --abort                      # discard half-done rebase
  rm -rf .git/rebase-merge .git/rebase-apply   # safety cleanup
'
# then re-run the skill
```

But always ask before destructive ops — `git rebase --abort` discards work.
