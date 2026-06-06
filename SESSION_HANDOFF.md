# Session handoff — IC-Light V2V quality troubleshooting

**Status as of 2026-06-06:** Render pipeline is mechanically stable. User reports output **video quality is poor** and wants to investigate from here (`comfyui-provisioner`) rather than continue from `davinci-agent`.

## Do NOT re-debug these — already fixed on `main` of `comfyui-stack-iclight-v2v`

| Commit | Fix |
|---|---|
| `c7bc035` | `ImageDetailTransfer` → `DetailTransfer` (kijai/ComfyUI-IC-Light) |
| `6fd7fad` | Wired `VAEDecode.vae`; renamed `ICLightApplyMaskGrey.mask` → `alpha`; added `SolidMask` + `GetImageSize` so mask is all-ones passthrough |
| `91f76d7` | gitignore Syncthing artifacts |
| `bde1f1c` | OOM workaround: `frame_load_cap 0→16`, `ImageScaleToTotalPixels 0.75→0.5 MP` |

And on `comfyui-provisioner` main:
| Commit | Fix |
|---|---|
| `d63cb15` | Provisioner shell bug: `IFS='|' read -r rel url sha` (was stripping only first delimiter) |
| `436db35` | Auto sendonly Syncthing folder for logs; `COMFYUI_LOG_LEVEL` env; `/pair-vastai-logs` |

Last verified run: 16 frames, 25 steps, ~1.69 it/s, completed in **31.60 s** with no OOM. Mechanically green.

## Current workflow knob state (`comfyui/IC_Light_FBC_Video2Video_Relight_v1.json`)

```
ImageScaleToTotalPixels  bilinear, 0.5 MP            <-- LOW (OOM workaround)
CheckpointLoaderSimple   realisticVisionV51_v51VAE.safetensors
ControlNetLoader         control_v11f1p_sd15_depth.pth
ControlNetApplyAdvanced  strength=0.75, start=0.0, end=0.75   <-- ends early
KSampler                 seed=42, steps=25, cfg=2.0, dpmpp_2m, karras, denoise=0.45
DetailTransfer           mode=add, blur_sigma=4.0, blend=1.0  <-- full additive
VHS_LoadVideo            frame_load_cap=16
VHS_VideoCombine         h264-mp4, yuv420p, crf=18, 24 fps
```

## Quality-leading hypotheses (ranked by likelihood)

1. **Resolution starvation.** 0.5 MP is the OOM bandaid. SD1.5 at sub-540p loses fine detail and skin texture. Next: bump back toward 0.75 MP with smaller `frame_load_cap` (8–12) to stay within 24 GB. Quality usually scales with pixel count more than step count here.
2. **CFG 2.0 is very low** for SD1.5 relighting. IC-Light examples typically use 2.0–7.0 — 2.0 sits at the floor and tends to wash detail. Try 3.5–5.0.
3. **ControlNet depth ends at 0.75.** Last 25% of denoise runs unguided → identity drift, blurry edges. Try `end_percent=1.0` (or 0.9) and consider raising strength to 0.8–0.9 for tighter structure lock.
4. **DetailTransfer add @ 4.0/1.0** — the "add" mode with blend=1.0 dumps high-frequency residue back in. This often looks like noise/grain or halos. Try `blend=0.5` first, or switch `add`→`multiply`/`overlay`. A/B with this node bypassed entirely.
5. **Denoise 0.45** may be too low for a real relight — the original lighting bleeds through. For IC-Light FBC typical V2V is 0.55–0.75. Push up after fixing CFG/ControlNet so changes are interpretable.
6. **h264 crf=18 is fine.** Don't blame the encoder until pixel-level frames out of `VAEDecode` look good.

## Suggested isolation order

1. Save a still frame out of `VAEDecode` (before DetailTransfer, before VideoCombine) and inspect it. This separates "model output is bad" from "post + encode is bad."
2. If the still is bad: knob ControlNet end → CFG → denoise → resolution, in that order.
3. If the still is good but video is bad: it's DetailTransfer or VideoCombine.

## Operating constraints (carry forward)

- **vast.ai is paid.** Confirm with user before re-launching an instance.
- **Edit `main` directly** for ongoing troubleshooting — no PR overhead. User explicitly approved.
- **Email for `comfyui-stack-iclight-v2v` commits:** `88331242+ismail-kattakath@users.noreply.github.com`. Other repos: `ismail@kattakath.com`.
- **Syncthing pair** is the source of truth for workflow + logs. Do not SSH unless Syncthing is broken. `./logs/` in the stack repo is gitignored and mirrors the instance's ComfyUI logs.
- Workflow JSON is **auto-saved by the ComfyUI frontend on Run** — if you hot-patch the file on disk, the user must close the canvas tab + hard-refresh before pressing Run, or the in-browser graph overwrites the patch.
- Don't touch the `/Users/aloshy/aloshy-ai/davinci-agent/` harness from here — it's a separate Resolve-focused project.

## Useful slash commands already in place

- `comfyui-stack-iclight-v2v`: `/watch-comfyui-logs` — silent background log watcher, interrupts on Traceback/OOM/node_errors/process exit, auto-stops after 10 min idle or 60 min cap.
- `comfyui-provisioner`: `/pair-vastai-logs <instance-id>` — sets up Syncthing receiveonly pair to pull the instance's ComfyUI logs to `./logs/`.

## Last instance

`39718734` at $0.5293/hr was last known active. Confirm status before assuming it's still up.
