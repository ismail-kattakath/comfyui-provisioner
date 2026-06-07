# Handoff — iclight-v2v relighting exploration + brainstorm backlog system

_Crystallized at end of session 2026-06-06. Resume with `/resume iclight-relight-and-backlog-handoff`._

## Live infrastructure
- **VastAI instance `39718734`** (RTX 4090) — **STILL RUNNING / BILLING.** ComfyUI on :18188,
  api-wrapper on :18288, Caddy auth-proxy on :8188. SSH via `vastai ssh-url 39718734` (host
  agent forwarded; not the ssh8 proxy). ⚠️ DECISION PENDING: keep it running for the next
  session or stop/destroy to save money (vast balance was ~$15 earlier).
- **Syncthing = container-only** (host never runs it — policy). Both folders synced
  receiveonly: `comfyui-logs`→`logs/`, `comfyui-workflows`→`comfyui/`. Heal anytime with
  `/sync-wire`. comfyui/ is a RECEIVEONLY mirror → edit workflows ON THE INSTANCE, not locally.

## Repos (all pushed)
- **comfyui-stack-iclight-v2v @ main `93d8e16`** — 7 workflows. Relighting ladder + verdict:
  - `Hybrid_Subject_LBM_Backdrop_Match_v2` — **USER'S PICK** (LBM-relit subject + neural
    harmonization backdrop; best cohesion).
  - `IC_Light_FBC_Whole_Relight_v3` — **best physical whole-frame relight** (YUV luminance-
    transfer: relight luma + original chroma; cast+ghosting fixed, native 1080×1920; minor
    residual shadow softness — a curves pass would polish it).
  - `FG_Whole_ColorGrade_BG_Match_v1` (flat statistical tint), `LBM_Relight_Space_Replica_v1`
    (pristine; subject-on-BG, "wrong" for keep-own-scene goal), IC-Light v1 + video v1.
  - Uncommitted/held locally: `IC_Light_FBC_Whole_Relight_v2.json` (superseded by v3) +
    cosmetic ComfyUI-resave drift on LBM/FG workflow JSONs (harmless; do NOT commit).
- **comfyui-provisioner @ main `6af1f0c`** — added: container Syncthing tooling +
  `/sync-wire` + session-start auto-heal; api-wrapper `COMFYUI_API_BASE` fix (both providers);
  the brainstorm **backlog system** (this session's last build).

## Brainstorm backlog system (live, Tier-1 in-session)
- `/idea <text>` = instant capture; `/backlog` = view; `touch .claude/backlog/AUTOPILOT` arms
  auto-dispatch (default OFF), `touch .claude/backlog/PAUSED` = kill-switch. Groomer subagent
  refines/reprioritizes, never executes. Guide: `.claude/backlog/OPERATING.md`.
- UNVERIFIED: the Stop-hook block-JSON shape that triggers auto-dispatch — confirm on first
  autopilot use. Capture/groom/view work regardless. Continuous grooming needs the Lead to
  re-arm the groomer (or wrap in `/loop`). Tier-2 (24/7 cron/SDK daemon) NOT built.

## ⚠️ Pending user actions
1. **Rotate 5 tokens** — HF / GitHub / Vast / Civitai / RunPod leaked into the transcript via a
   shell-snapshot echo earlier this session.
2. **Decide the vast instance** (running/billing — see above).

## Optional next steps (not started)
- IC-Light v3: add a curves/levels pass to recover shadow contrast.
- Hybrid v3: give the backdrop real light-direction (its remaining flatness).
- Backlog: smoke-test `/idea`→groom→`/backlog`; tune priority/conflict tagging; build Tier-2.

## State at exit
All subagents stopped (perpetual log watcher NOT re-armed). All commits pushed. Memory updated
(see MEMORY.md: lbm-relight-workflow, syncthing-via-devcontainer-only, apiwrapper-comfyui-backend-port,
perpetual-log-watcher-policy, brainstorm-capture-groom-dispatch-system).
