#!/usr/bin/env bash
# scripts/preflight-stack.sh
#
# GPU-free readiness check for a ComfyUI "stack" repo. Verifies a stack is
# *composable* — config parses, resources are reachable, hashes are knowable,
# the workflow's model references are accounted for — BEFORE renting a GPU.
#
# Design principles (see CLAUDE.md):
#   - Zero-trust URLs: github.com/huggingface.co/civitai.com are ALWAYS accessed
#     with $GITHUB_TOKEN/$HF_TOKEN/$CIVITAI_API_KEY. No URL is assumed public.
#     A missing required token is NOT-READY, never a silent skip.
#   - Maximal pinning purity: NODE_MAP wants a full fetchable commit SHA;
#     MODEL_MAP wants a recorded sha256; Civitai wants a versioned id + sha256.
#   - Calibrated tiers: T0..T3 are correctness gates (the known-good corpus
#     passes them); purity is a separate dimension — WARN by default, hard FAIL
#     under --strict (the remediation backlog toward "maximum purity").
#
# Read-only. Never downloads model bytes (HEAD / 1-byte range GET only).
#
# Usage:
#   scripts/preflight-stack.sh [--strict] [--verify-pins] [--json] [STACK_DIR]
#     STACK_DIR     stack repo root (default: cwd). Must contain
#                   provisioner-config.sh and comfyui/.
#     --strict      promote purity WARNs (unpinned nodes, unrecorded sha256,
#                   floating HF refs) to hard failures.
#     --verify-pins network-verify each NODE_MAP commit SHA is fetchable from
#                   its remote (one git fetch-by-sha per node; slower).
#     --json        emit a machine-readable JSON verdict instead of text.
#   Optional env:
#     COMFYUI_DIR        if set, also reports which models are already on disk.
#     PREFLIGHT_ALLOW    space-separated basenames the workflow may reference
#                        without a MAP entry (node-managed / base-image weights).
#   Stacks may declare, in provisioner-config.sh, an optional:
#     MANUAL_MODELS=( "loras/qwen_edit/next-scene_lora.safetensors" )
#   array — entries known to require manual placement (treated as known, not gaps).
#
# Exit codes (à la `terraform plan -detailed-exitcode`):
#   0  READY        all correctness gates pass; nothing blocking
#   2  NEEDS-FETCH  reachable + composable, but resources not yet on disk/locked
#   1  NOT-READY    a hard failure (dead URL, missing token, hash mismatch,
#                   or — under --strict — a purity violation)

set -euo pipefail

trap 'rc=$?; [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] && [ "$rc" -ne 2 ] && \
  printf "[preflight] aborted (rc=%s) at line %s\n" "$rc" "$LINENO" >&2' EXIT

# ---------- args ----------
STRICT=0; VERIFY_PINS=0; JSON=0; STACK_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict)      STRICT=1 ;;
    --verify-pins) VERIFY_PINS=1 ;;
    --json)        JSON=1 ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)            echo "unknown flag: $1" >&2; exit 64 ;;
    *)             STACK_DIR="$1" ;;
  esac
  shift
done
STACK_DIR="${STACK_DIR:-$PWD}"
CFG="$STACK_DIR/provisioner-config.sh"
WF_DIR="$STACK_DIR/comfyui"

# ---------- output helpers ----------
declare -a FAILS=() WARNS=() FETCHES=()
tier_line() { printf '  %-9s %s\n' "$1" "$2"; }
fail() { FAILS+=("$1");  [ "$JSON" = 1 ] || tier_line "[FAIL]"  "$1"; }
warn() { WARNS+=("$1");  [ "$JSON" = 1 ] || tier_line "[WARN]"  "$1"; }
fetch(){ FETCHES+=("$1");[ "$JSON" = 1 ] || tier_line "[FETCH]" "$1"; }
ok()   {                 [ "$JSON" = 1 ] || tier_line "[OK]"    "$1"; }
hdr()  { [ "$JSON" = 1 ] || printf '\n== %s ==\n' "$1"; }
# purity finding: hard FAIL under --strict, else WARN
impure() { if [ "$STRICT" = 1 ]; then fail "$1"; else warn "$1 (purity; --strict to enforce)"; fi; }

is_hex()  { case "$1" in *[!0-9a-fA-F]*) return 1;; "") return 1;; *) return 0;; esac; }
is_sha256(){ [ "${#1}" -eq 64 ] && is_hex "$1"; }
is_commit(){ { [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]; } && is_hex "$1"; }
host_of() { local u="${1#*://}"; printf '%s' "${u%%/*}"; }

# ---------- T0: structural ----------
hdr "T0 structural"
[ -f "$CFG" ]    || { fail "no provisioner-config.sh at $STACK_DIR"; }
[ -d "$WF_DIR" ] || { fail "no comfyui/ dir at $STACK_DIR"; }
if [ ${#FAILS[@]} -ne 0 ]; then
  [ "$JSON" = 1 ] || echo; echo "Stack: NOT-READY (structural)"; exit 1
fi
# Source config in THIS shell so we can read the arrays. It is trusted repo content.
# shellcheck disable=SC1090
set +u; source "$CFG"; set -u
MISSING_ARR=()
for a in NODE_MAP ALIAS_MAP MODEL_MAP MODEL_MAP_CIVITAI WORKFLOW_MAP; do
  declare -p "$a" >/dev/null 2>&1 || MISSING_ARR+=("$a")
done
if [ ${#MISSING_ARR[@]} -ne 0 ]; then
  fail "config missing required array(s): ${MISSING_ARR[*]}"
else
  ok "config sources cleanly; 5 arrays defined \
(NODE=${#NODE_MAP[@]} ALIAS=${#ALIAS_MAP[@]} MODEL=${#MODEL_MAP[@]} CIVITAI=${#MODEL_MAP_CIVITAI[@]} WORKFLOW=${#WORKFLOW_MAP[@]})"
fi
# normalize optional arrays
declare -a MANUAL_MODELS_LOCAL=()
if declare -p MANUAL_MODELS >/dev/null 2>&1; then MANUAL_MODELS_LOCAL=("${MANUAL_MODELS[@]}"); fi
read -r -a ALLOW_EXTRA <<<"${PREFLIGHT_ALLOW:-}"

# Collect node folder names (field 3) for alias checks.
declare -a NODE_FOLDERS=()
for e in "${NODE_MAP[@]:-}"; do
  IFS='|' read -r _url _pin _folder _extra <<<"$e"
  [ -n "${_folder:-}" ] && NODE_FOLDERS+=("$_folder")
done

# ---------- T1: referential integrity ----------
hdr "T1 referential"
t1_fail=0
for e in "${WORKFLOW_MAP[@]:-}"; do
  IFS='|' read -r fname _fallback <<<"$e"
  [ -z "${fname:-}" ] && continue
  if [ ! -f "$WF_DIR/$fname" ]; then fail "WORKFLOW_MAP '$fname' not found in comfyui/"; t1_fail=1; fi
done
# alias targets must match a node folder (case-insensitive — case-only renames are deliberate)
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
declare -a NF_LC=(); for f in "${NODE_FOLDERS[@]:-}"; do NF_LC+=("$(lc "$f")"); done
for e in "${ALIAS_MAP[@]:-}"; do
  tgt="${e##*:}"; [ -z "$tgt" ] && continue
  hit=0; tlc="$(lc "$tgt")"
  for f in "${NF_LC[@]:-}"; do [ "$f" = "$tlc" ] && { hit=1; break; }; done
  if [ "$hit" -eq 0 ]; then fail "ALIAS_MAP target '$tgt' matches no NODE_MAP folder"; t1_fail=1; fi
done
# node folder uniqueness
dups="$(printf '%s\n' "${NODE_FOLDERS[@]:-}" | sort | uniq -d || true)"
[ -n "$dups" ] && { fail "duplicate NODE_MAP folder name(s): $(echo "$dups" | tr '\n' ' ')"; t1_fail=1; }
# civitai entries must carry a 64-hex sha256
for e in "${MODEL_MAP_CIVITAI[@]:-}"; do
  IFS='|' read -r path _url sha <<<"$e"
  [ -z "${path:-}" ] && continue
  is_sha256 "${sha:-}" || { fail "CIVITAI entry '$path' lacks a valid sha256"; t1_fail=1; }
done
[ "$t1_fail" -eq 0 ] && ok "WORKFLOW files present; ALIAS↔NODE consistent; folders unique; Civitai sha256 valid"

# ---------- token preflight (zero-trust) ----------
hdr "Auth (zero-trust)"
declare -A NEED_TOKEN=()
note_host() {
  case "$(host_of "$1")" in
    *github.com)      NEED_TOKEN[GITHUB_TOKEN]=1 ;;
    *huggingface.co)  NEED_TOKEN[HF_TOKEN]=1 ;;
    *civitai.com)     NEED_TOKEN[CIVITAI_API_KEY]=1 ;;
    "" ) : ;;
    *) warn "unrecognized host '$(host_of "$1")' — no token mapping; cannot enforce auth ($1)" ;;
  esac
}
for e in "${NODE_MAP[@]:-}";          do IFS='|' read -r u _ _ _ <<<"$e"; [ -n "${u:-}" ] && note_host "$u"; done
for e in "${MODEL_MAP[@]:-}";         do IFS='|' read -r _ u _ <<<"$e";   [ -n "${u:-}" ] && note_host "$u"; done
for e in "${MODEL_MAP_CIVITAI[@]:-}"; do IFS='|' read -r _ u _ <<<"$e";   [ -n "${u:-}" ] && note_host "$u"; done
for tok in "${!NEED_TOKEN[@]}"; do
  if [ -z "${!tok:-}" ]; then fail "\$$tok required (stack references its host) but is unset"
  else ok "\$$tok present (required by this stack)"; fi
done
# inline-credential leak scan
if grep -nEq '(gh[pousr]_[A-Za-z0-9]{20,}|hf_[A-Za-z0-9]{20,}|[Bb]earer[[:space:]]+[A-Za-z0-9._-]{20,}|://[^/[:space:]@]+:[^/[:space:]@]+@)' "$CFG"; then
  fail "provisioner-config.sh appears to contain an inline credential — secrets must come from env tokens only"
fi

# authed wrappers
gh_authed() { # rewrite a github https url to embed the token
  local u="$1"
  case "$u" in
    https://github.com/*) printf 'https://x-access-token:%s@github.com/%s' "${GITHUB_TOKEN:-}" "${u#https://github.com/}" ;;
    *) printf '%s' "$u" ;;
  esac
}
hf_status_etag() { # echo "<final_http_code> <sha256-or-empty>"
  local u="$1" hdrs code etag
  hdrs="$(curl -sIL --max-time 30 -H "Authorization: Bearer ${HF_TOKEN:-}" "$u" 2>/dev/null || true)"
  code="$(printf '%s' "$hdrs" | awk 'BEGIN{c=0} /^HTTP\//{c=$2} END{print c}')"
  etag="$(printf '%s' "$hdrs" | awk 'tolower($1)=="x-linked-etag:"{gsub(/[\r"]/,"",$2); print $2}' | tail -n1)"
  printf '%s %s\n' "${code:-000}" "${etag:-}"
}
civitai_reachable() { # 200/206 on 1-byte authed range GET == reachable (R2 presigned rejects HEAD)
  local u="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 30 -r 0-0 \
          -H "Authorization: Bearer ${CIVITAI_API_KEY:-}" "$u" 2>/dev/null || true)"
  [ "$code" = "200" ] || [ "$code" = "206" ]
}

# ---------- T2: reachability + T3: provenance (interleaved per model) ----------
hdr "T2 reachability / T3 provenance"
declare -A MODEL_SHA=()       # rel-path -> sha256 (recorded or etag-derived)
t2_fail=0; recorded=0; obtainable=0; total_hf=0
for e in "${MODEL_MAP[@]:-}"; do
  IFS='|' read -r rel url sha <<<"$e"
  [ -z "${rel:-}" ] && continue
  total_hf=$((total_hf+1))
  case "$(host_of "$url")" in
    *huggingface.co)
      read -r code etag < <(hf_status_etag "$url") || true
      if [ "$code" = "200" ]; then ok "reachable: $rel (HF 200)"
      else fail "unreachable: $rel — HF HEAD $code ($url)"; t2_fail=1; fi
      if is_sha256 "${sha:-}"; then recorded=$((recorded+1)); MODEL_SHA[$rel]="$sha"
      elif is_sha256 "$etag"; then obtainable=$((obtainable+1)); MODEL_SHA[$rel]="$etag"
      else warn "no sha256 for $rel (not recorded, no etag) — integrity unverifiable"; fi
      case "$url" in *"/resolve/main/"*|*"/resolve/master/"*) impure "$rel pinned to a floating HF ref (/resolve/main/) — pin a commit revision";; esac
      ;;
    *)
      # non-HF public URL: still probe, but we have no token mapping
      code="$(curl -s -o /dev/null -w '%{http_code}' -IL --max-time 30 "$url" 2>/dev/null || true)"
      if [ "$code" = "200" ]; then ok "reachable: $rel ($code)"; else fail "unreachable: $rel — HTTP $code ($url)"; t2_fail=1; fi
      is_sha256 "${sha:-}" && { recorded=$((recorded+1)); MODEL_SHA[$rel]="$sha"; } || warn "no sha256 for $rel"
      ;;
  esac
done
for e in "${MODEL_MAP_CIVITAI[@]:-}"; do
  IFS='|' read -r rel url sha <<<"$e"
  [ -z "${rel:-}" ] && continue
  if civitai_reachable "$url"; then ok "reachable: $rel (Civitai 200/206)"; else fail "unreachable: $rel — Civitai range-GET failed ($url)"; t2_fail=1; fi
  is_sha256 "${sha:-}" && { recorded=$((recorded+1)); MODEL_SHA[$rel]="$sha"; }
  case "$url" in *"/api/download/models/"[0-9]*) :;; *) impure "$rel Civitai URL is not a versioned /models/<id> pin";; esac
done

# nodes: reachability (auth-always) + pin purity (+ optional fetch verification)
hdr "Nodes (reachability + pin purity)"
for e in "${NODE_MAP[@]:-}"; do
  IFS='|' read -r url pin folder _extra <<<"$e"
  [ -z "${url:-}" ] && continue
  if git ls-remote "$(gh_authed "$url")" >/dev/null 2>&1; then ok "reachable: ${folder:-$url}"
  else fail "unreachable git repo: ${folder:-$url} ($url)"; t2_fail=1; fi
  if [ -z "${pin:-}" ]; then impure "${folder:-$url} has NO commit pin (floating HEAD)"
  elif ! is_commit "$pin"; then impure "${folder:-$url} pin '$pin' is not a full commit SHA"
  elif [ "$VERIFY_PINS" = 1 ]; then
    tmp="$(mktemp -d)"; git init -q "$tmp" 2>/dev/null || true
    if git -C "$tmp" fetch -q --depth 1 "$(gh_authed "$url")" "$pin" 2>/dev/null \
       && git -C "$tmp" cat-file -e "${pin}^{commit}" 2>/dev/null; then ok "pin fetchable: ${folder} @ ${pin:0:12}"
    else fail "pin NOT fetchable from remote: ${folder} @ ${pin:0:12} (gc'd or wrong?)"; t2_fail=1; fi
    rm -rf "$tmp"
  fi
done

# ---------- T3 verdict line + on-disk readiness ----------
hdr "T3 provenance"
if [ "$total_hf" -gt 0 ] || [ "${#MODEL_MAP_CIVITAI[@]}" -gt 0 ]; then
  ok "sha256 recorded:${recorded}  obtainable-via-etag:${obtainable}  hf-total:${total_hf}"
fi
[ "$recorded" -lt "$total_hf" ] && impure "$((total_hf-recorded)) HF model(s) have no RECORDED sha256 — run stack-lock to pin"

# on-disk check (optional; uses recorded/obtainable sha when present)
if [ -n "${COMFYUI_DIR:-}" ] && [ -d "${COMFYUI_DIR:-/nonexistent}/models" ]; then
  hdr "On-disk (COMFYUI_DIR=$COMFYUI_DIR)"
  for e in "${MODEL_MAP[@]:-}" "${MODEL_MAP_CIVITAI[@]:-}"; do
    IFS='|' read -r rel _ _ <<<"$e"; [ -z "${rel:-}" ] && continue
    f="$COMFYUI_DIR/models/$rel"
    if [ -f "$f" ]; then
      want="${MODEL_SHA[$rel]:-}"
      if [ -n "$want" ]; then
        got="$(sha256sum "$f" | awk '{print $1}')"
        if [ "$got" = "$want" ]; then ok "on-disk + verified: $rel"
        else fail "HASH MISMATCH on disk: $rel (want ${want:0:12}.. got ${got:0:12}..)"; fi
      else warn "on-disk but no sha to verify: $rel"; fi
    else fetch "not on disk: $rel"; fi
  done
fi

# ---------- T4: workflow ↔ resource coherence (advisory) ----------
hdr "T4 coherence (advisory)"
# build covered-set: every MAP target (full rel path) + its basename
declare -A COVERED=()
for e in "${MODEL_MAP[@]:-}" "${MODEL_MAP_CIVITAI[@]:-}"; do
  IFS='|' read -r rel _ _ <<<"$e"; [ -z "${rel:-}" ] && continue
  COVERED["$rel"]=1; COVERED["$(basename "$rel")"]=1
done
for m in "${MANUAL_MODELS_LOCAL[@]:-}"; do [ -n "$m" ] || continue; COVERED["$m"]=1; COVERED["$(basename "$m")"]=1; done
for a in "${ALLOW_EXTRA[@]:-}"; do [ -n "$a" ] && COVERED["$a"]=1; done

extract_refs() { # print model-file refs from a workflow JSON, skipping Note nodes
  local wf="$1"
  if command -v jq >/dev/null 2>&1; then
    # Drop Note/MarkdownNote nodes (their text is documentation, not loader inputs),
    # then recurse EVERY descendant string of the remaining nodes — model names live
    # at varying widget depths across ComfyUI versions, so a shallow walk misses them.
    { jq -r '(.nodes // [])
              | map(select((.type//""|ascii_downcase|test("note"))|not))
              | .. | strings' "$wf" 2>/dev/null
      jq -r '(if (type=="object" and (has("nodes")|not)) then [.[]] else [] end)
              | map(select((.class_type//""|ascii_downcase|test("note"))|not))
              | .. | strings' "$wf" 2>/dev/null
    } | grep -Eo '[A-Za-z0-9._/-]+\.(safetensors|ckpt|pt|pth|gguf|bin)' || true
  else
    grep -Eo '[A-Za-z0-9._/-]+\.(safetensors|ckpt|pt|pth|gguf|bin)' "$wf" || true
  fi
}
declare -A SEEN_REF=()
# Audit ONLY the workflows this stack actually deploys (WORKFLOW_MAP), not every
# stray/extra/sync-conflict JSON sitting in comfyui/.
for wfe in "${WORKFLOW_MAP[@]:-}"; do
  IFS='|' read -r fname _ <<<"$wfe"; [ -z "${fname:-}" ] && continue
  wf="$WF_DIR/$fname"; [ -f "$wf" ] || continue
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    base="$(basename "$ref")"
    [ -n "${COVERED[$ref]:-}${COVERED[$base]:-}" ] && continue
    [ -n "${SEEN_REF[$base]:-}" ] && continue
    SEEN_REF["$base"]=1
    warn "workflow references '$base' — not in any MAP, allowlist, or MANUAL_MODELS ($(basename "$wf"))"
  done < <(extract_refs "$wf")
done
[ ${#SEEN_REF[@]} -eq 0 ] && ok "every workflow model reference is covered by a MAP/allow/manual entry"

# ---------- verdict ----------
nf=${#FAILS[@]}; nw=${#WARNS[@]}; ng=${#FETCHES[@]}
if [ "$JSON" = 1 ]; then
  j() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  arr() { local first=1 x; printf '['; for x in "$@"; do [ -z "$x" ] && continue; [ "$first" = 1 ] || printf ','; printf '"%s"' "$(j "$x")"; first=0; done; printf ']'; }
  if   [ "$nf" -gt 0 ]; then verdict=NOT-READY; code=1
  elif [ "$ng" -gt 0 ]; then verdict=NEEDS-FETCH; code=2
  else verdict=READY; code=0; fi
  printf '{"stack":"%s","verdict":"%s","strict":%s,"fails":%s,"warns":%s,"needsFetch":%s}\n' \
    "$(j "$(basename "$STACK_DIR")")" "$verdict" "$STRICT" \
    "$(arr "${FAILS[@]:-}")" "$(arr "${WARNS[@]:-}")" "$(arr "${FETCHES[@]:-}")"
  exit "$code"
fi

echo
if [ "$nf" -gt 0 ]; then
  echo "Stack: NOT-READY — ${nf} fail, ${nw} warn, ${ng} need-fetch"; exit 1
elif [ "$ng" -gt 0 ]; then
  echo "Stack: NEEDS-FETCH — 0 fail, ${nw} warn, ${ng} resource(s) reachable but not on disk"; exit 2
else
  echo "Stack: READY — 0 fail, ${nw} warn"; exit 0
fi
