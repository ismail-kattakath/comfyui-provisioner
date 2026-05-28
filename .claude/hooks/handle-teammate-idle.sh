#!/usr/bin/env bash
# Injects a systemMessage guiding the lead to verify teammate completion before idle is approved.
printf '%s' '{
  "type": "systemMessage",
  "content": "A teammate is about to go idle in the comfyui-provisioner project. Before approving, verify the teammate has:\n\n1. Reported its primary result to the lead — instance ID + running status if deploying; explicit PASS or FAIL with evidence if verifying; named list of present/missing nodes if auditing.\n2. If a VastAI instance was created: recorded the instance ID and its actual_status.\n3. If an error was encountered (boot failure, SSH refused, model download failed, poll timeout): explicitly notified the lead with the error details and instance ID.\n4. Left no in-progress actions unresolved (interrupted poll loop, half-written file, uncommitted fix).\n\nIf any of these are incomplete, respond '\''block: <specific missing item>'\''. If all are done or none apply, respond '\''approve'\''."
}'
exit 0
