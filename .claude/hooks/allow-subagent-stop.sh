#!/usr/bin/env bash
# SubagentStop hook — explicit no-op approval.
# The Lead's own CLAUDE.md governs what it does on re-invocation.
# Command hook (zero LLM cost) replacing the previous prompt hook that always said "approve".
exit 0
