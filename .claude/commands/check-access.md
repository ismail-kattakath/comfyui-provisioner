---
description: >
  Connectivity & auth preflight. Verifies every credential and endpoint the
  provisioner depends on (HuggingFace, GitHub, Civitai, Vast.ai, RunPod, the
  forwarded SSH agent) and navigates remediation for each gap. Optionally
  SSH-probes a running instance. Use: /check-access [instance-id]
argument-hint: "[instance-id]   (optional — also SSH-probes that instance)"
allowed-tools: Bash, Read
---

# /check-access

Run the deterministic access checker and *navigate* the user through fixing any
gap. This is the first thing to run at the start of a session, after editing
`.env`, or before any deploy / instance-driving task — it answers "is everything
I need actually wired up?" without renting a GPU.

Wraps `scripts/check-access.sh` (read-only; never echoes token values). The
script holds the truth table; this command interprets it and guides fixes.

## Usage

```
/check-access
/check-access 39718734
```

First token of `$ARGUMENTS` (optional) = `INSTANCE_ID`. If given, the checker
also resolves `vastai ssh-url <id>` and confirms SSH actually connects.

## Step 1 — Run the checker

```bash
ROOT="$(git rev-parse --show-toplevel)"
if [ -n "$ARGUMENTS" ]; then
  bash "$ROOT/scripts/check-access.sh" --instance "$ARGUMENTS"
else
  bash "$ROOT/scripts/check-access.sh"
fi
```

It prints `[OK] / [WARN] / [FAIL]` per service, a `-> remediation` hint under
each non-OK line, and a final `READY` / `NOT-READY` verdict. Exit code: `0`
READY, `1` NOT-READY (a required credential missing/invalid).

## Step 2 — Navigate remediation

Required services are **HuggingFace, GitHub, Civitai, Vast.ai**. RunPod and SSH
are **advisory** (situational). For each non-OK line, guide the user — do not
guess or auto-edit `.env` with secrets:

| Symptom | What to tell the user |
|---|---|
| `HF_TOKEN / GITHUB_TOKEN / CIVITAI_API_KEY / VAST_API_KEY not set` | Add it to `.env` (the checker prints the issuer URL). `.env` is gitignored and host-mounted, so it survives rebuilds. The `load-env.sh` SessionStart hook + direnv pick it up next turn. |
| token `rejected` / HTTP non-200 | Credential is present but invalid/expired — regenerate at the issuer and replace in `.env`. |
| Vast.ai `not authenticated` but key is in `.env` | The MCP/CLI may not have reloaded — confirm `VAST_API_KEY` is uncommented; or `vastai set api-key <KEY>` writes the CLI's own config file. |
| `SSH agent forwarded but NO keys loaded` | On the **host** (not the container): `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`, verify with `ssh-add -l`. The `Host *` block in `~/.ssh/config` makes this survive host reboots. See CLAUDE.md "SSH access from the devcontainer". |
| `SSH agent not forwarded` | Not in a VS Code devcontainer, or agent forwarding disabled. SSH to instances won't work until a key is available. |
| instance `ssh-url could not resolve` | Instance isn't running — `vastai show instances`, wait for `actual_status=running`. |

## Step 3 — Report

State the verdict plainly (`READY` / `NOT-READY`) and list only the items that
need action, each with its one-line fix. If everything is OK, say so and stop —
do not over-explain. If a paid action (renting/relaunching a Vast.ai instance)
would be the logical next step, confirm with the user first.

## Notes

- The checker reads `.env` itself, so it works even in a bare shell where the
  SessionStart hook hasn't run.
- It never prints secret values — safe to run and paste output anywhere.
- `vastai execute` only works on **stopped** instances; live instances need SSH
  (hence the agent check). Pair with `/verify-stack <id>` for a deeper,
  on-instance check (nodes, models, ComfyUI HTTP).
