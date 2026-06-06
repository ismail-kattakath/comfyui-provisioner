#!/usr/bin/env bash
# scripts/check-access.sh
#
# GPU-free connectivity & auth preflight for the comfyui-provisioner workflow.
# Verifies every credential + endpoint the framework depends on BEFORE you try
# to deploy or drive an instance, and prints concrete remediation for each gap.
#
# Checks:
#   - Tokens/API auth: HuggingFace, GitHub, Civitai, Vast.ai, RunPod (optional)
#   - SSH: the VS Code-forwarded agent (and the keys loaded in it)
#   - Optionally (--instance ID): live SSH reachability of a running instance
#
# Read-only. Never writes anything. Never echoes token values.
# Routes nothing through the web-tool hooks — pure CLI/curl inside one process.
#
# Usage:
#   scripts/check-access.sh [--instance ID] [--quiet]
#     --instance ID   also test SSH reachability of Vast.ai instance ID
#     --quiet         suppress per-check lines; print only the final verdict
#
# Exit codes (à la preflight-stack.sh):
#   0  READY       all REQUIRED services authenticated (HF, GitHub, Civitai, Vast.ai)
#   1  NOT-READY   a required credential is missing or rejected
#                  (RunPod + SSH are advisory WARNs, never hard failures)

set -uo pipefail   # deliberately NOT -e: individual probes are allowed to fail

# ---------- args ----------
QUIET=0; INSTANCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --instance)   INSTANCE="${2:-}"; shift ;;
    --instance=*) INSTANCE="${1#*=}" ;;
    --quiet)      QUIET=1 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           echo "unknown flag: $1" >&2; exit 64 ;;
    *)            INSTANCE="$1" ;;   # bare arg = instance id
  esac
  shift
done

# ---------- load .env (direnv usually does this; be self-sufficient too) ----------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env" 2>/dev/null; set +a; }

# ---------- output helpers ----------
REQ_FAIL=0; ADV_WARN=0
say(){ [ "$QUIET" = 1 ] || printf '%s\n' "$1"; }
hdr(){ [ "$QUIET" = 1 ] || printf '\n== %s ==\n' "$1"; }
ok(){   say "  [OK]    $1"; }
warn(){ say "  [WARN]  $1"; ADV_WARN=$((ADV_WARN+1)); }
fail(){ say "  [FAIL]  $1"; REQ_FAIL=$((REQ_FAIL+1)); }
hint(){ say "          -> $1"; }

http_code(){ # url [auth-header] -> prints HTTP status code (000 on failure)
  if [ -n "${2:-}" ]; then
    curl -sS --max-time 15 -o /dev/null -w '%{http_code}' -H "$2" "$1" 2>/dev/null || echo 000
  else
    curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000
  fi
}

hdr "Tokens & API auth"

# --- HuggingFace (required) ---
if [ -z "${HF_TOKEN:-}" ]; then
  fail "HuggingFace: HF_TOKEN not set"
  hint "add HF_TOKEN=hf_... to .env  (https://hf.co/settings/tokens)"
else
  name=$(curl -sS --max-time 15 -H "Authorization: Bearer $HF_TOKEN" \
    https://huggingface.co/api/whoami-v2 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
  if [ -n "$name" ]; then ok "HuggingFace: $name"
  else fail "HuggingFace: HF_TOKEN rejected"; hint "token expired/invalid — regenerate at https://hf.co/settings/tokens"; fi
fi

# --- GitHub (required) ---
if [ -z "${GITHUB_TOKEN:-}" ]; then
  fail "GitHub: GITHUB_TOKEN not set"
  hint "add GITHUB_TOKEN=... to .env  (or paste \`gh auth token\` output)"
else
  login=$(curl -sS --max-time 15 -H "Authorization: Bearer $GITHUB_TOKEN" \
    https://api.github.com/user 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('login',''))" 2>/dev/null)
  if [ -n "$login" ]; then ok "GitHub: $login"
  else fail "GitHub: token rejected"; hint "regenerate a PAT with repo + workflow scopes"; fi
fi

# --- Civitai (required) ---
if [ -z "${CIVITAI_API_KEY:-}" ]; then
  fail "Civitai: CIVITAI_API_KEY not set"
  hint "add CIVITAI_API_KEY=... to .env  (https://civitai.com/user/account)"
else
  code=$(http_code "https://civitai.com/api/v1/models?limit=1" "Authorization: Bearer $CIVITAI_API_KEY")
  if [ "$code" = "200" ]; then ok "Civitai: authenticated"
  else fail "Civitai: HTTP $code"; hint "key invalid or civitai unreachable"; fi
fi

# --- Vast.ai (required) ---
VA=()
if command -v vastai >/dev/null 2>&1; then
  [ -n "${VAST_API_KEY:-}" ] && VA=(--api-key "$VAST_API_KEY")
  uinfo=$(vastai show user "${VA[@]}" --raw 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('%s|%.2f'%(d.get('email',''),d.get('credit',0.0)))" 2>/dev/null)
  if [ -n "$uinfo" ] && [ "${uinfo%%|*}" != "" ]; then
    ok "Vast.ai: ${uinfo%%|*} (balance \$${uinfo##*|})"
  else
    fail "Vast.ai: not authenticated"
    hint "set VAST_API_KEY in .env, or run: vastai set api-key <KEY>"
  fi
else
  fail "Vast.ai: vastai CLI not installed"; hint "pip install --user vastai"
fi

# --- RunPod (advisory: only needed when deploying to RunPod) ---
if [ -z "${RUNPOD_API_KEY:-}" ]; then
  warn "RunPod: RUNPOD_API_KEY not set (optional — only for RunPod deploys)"
  hint "add RUNPOD_API_KEY=rpa_... to .env  (https://runpod.io/console/user/settings)"
else
  code=$(http_code "https://rest.runpod.io/v1/pods" "Authorization: Bearer $RUNPOD_API_KEY")
  if [ "$code" = "200" ]; then ok "RunPod: authenticated"
  else warn "RunPod: HTTP $code (key invalid?)"; fi
fi

hdr "SSH (instance access)"

# --- forwarded agent ---
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  ids=$(ssh-add -l 2>/dev/null)
  if [ -n "$ids" ] && ! printf '%s' "$ids" | grep -qi 'no identities'; then
    n=$(printf '%s\n' "$ids" | grep -c .)
    ok "SSH agent: forwarded, $n key(s) loaded"
  else
    warn "SSH agent: forwarded but NO keys loaded"
    hint "on the HOST run: ssh-add --apple-use-keychain ~/.ssh/id_ed25519 (then ssh-add -l)"
  fi
else
  warn "SSH agent: not forwarded (SSH_AUTH_SOCK unset)"
  hint "if not in a VS Code devcontainer, load a key locally; SSH_KEY_FILE is only for provisioning"
fi

# --- optional: live instance reachability ---
if [ -n "$INSTANCE" ]; then
  hdr "Instance $INSTANCE"
  if command -v vastai >/dev/null 2>&1; then
    url=$(vastai ssh-url "$INSTANCE" "${VA[@]}" 2>/dev/null)
    if [ -z "$url" ] || [ "${url#ssh://}" = "$url" ]; then
      warn "ssh-url: could not resolve (instance not running?)"
      hint "vastai show instances — confirm actual_status=running"
    else
      hp="${url#ssh://root@}"; h="${hp%:*}"; p="${hp##*:}"
      if ssh -p "$p" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=15 -o BatchMode=yes "root@$h" 'echo ok' 2>/dev/null | grep -q ok; then
        ok "SSH: connected to root@$h:$p"
      else
        warn "SSH: could not connect to $h:$p"
        hint "ensure the agent holds the key the instance authorizes (ssh-add -l)"
      fi
    fi
  else
    warn "instance check skipped: vastai CLI not installed"
  fi
fi

hdr "Verdict"
if [ "$REQ_FAIL" -eq 0 ]; then
  printf 'READY — all required services authenticated (%s advisory warning(s))\n' "$ADV_WARN"
  exit 0
else
  printf 'NOT-READY — %s required credential(s) missing/invalid, %s advisory warning(s)\n' "$REQ_FAIL" "$ADV_WARN"
  exit 1
fi
