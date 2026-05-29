#!/usr/bin/env bash
# scripts/stack-lock.sh
#
# Record provenance for a ComfyUI stack so it can reach "maximum purity":
#   - backfill each MODEL_MAP entry with its sha256 (from HuggingFace's
#     X-Linked-Etag, which IS the file's sha256) -> upgrades preflight T3 from
#     "obtainable" to "recorded".
#   - (optional) pin every empty NODE_MAP commit to the remote's current HEAD.
#
# Zero-trust: HF is always queried with $HF_TOKEN, GitHub with $GITHUB_TOKEN.
# DRY-RUN by default — prints the proposed lock and mutates nothing. Pass
# --write to edit provisioner-config.sh in place (a .bak copy is kept).
#
# Usage:
#   scripts/stack-lock.sh [--write] [--pin-nodes] [--pin-hf-rev] [STACK_DIR]
#     STACK_DIR     stack repo root (default: cwd)
#     --write       apply changes to provisioner-config.sh (keeps a .bak)
#     --pin-nodes   resolve empty NODE_MAP pins to current remote HEAD sha
#     --pin-hf-rev  rewrite floating HF "/resolve/main/" (or master) URLs to a
#                   pinned "/resolve/<commit>/" using HF's X-Repo-Commit header
#                   — this is what makes preflight --strict fully green
#
# This is content-addressing (à la pip --hash / OCI digests): the sha256 lives
# in the trusted, version-controlled stack repo and is recomputed on download.

set -euo pipefail

WRITE=0; PIN_NODES=0; PIN_HFREV=0; STACK_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write)      WRITE=1 ;;
    --pin-nodes)  PIN_NODES=1 ;;
    --pin-hf-rev) PIN_HFREV=1 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "unknown flag: $1" >&2; exit 64 ;;
    *)           STACK_DIR="$1" ;;
  esac
  shift
done
STACK_DIR="${STACK_DIR:-$PWD}"
CFG="$STACK_DIR/provisioner-config.sh"
[ -f "$CFG" ] || { echo "ERROR: no provisioner-config.sh at $STACK_DIR" >&2; exit 1; }
: "${HF_TOKEN:?HF_TOKEN required (zero-trust: HF is never anonymous)}"

# shellcheck disable=SC1090
set +u; source "$CFG"; set -u

is_hex() { case "$1" in *[!0-9a-fA-F]*|"") return 1;; *) return 0;; esac; }
is_sha256() { [ "${#1}" -eq 64 ] && is_hex "$1"; }
host_of() { local u="${1#*://}"; printf '%s' "${u%%/*}"; }
gh_authed() { case "$1" in https://github.com/*) printf 'https://x-access-token:%s@github.com/%s' "${GITHUB_TOKEN:-}" "${1#https://github.com/}";; *) printf '%s' "$1";; esac; }

# tab-separated lock proposals consumed by the --write python pass
LOCK_TSV="$(mktemp)"; PIN_TSV="$(mktemp)"; REV_TSV="$(mktemp)"
trap 'rm -f "$LOCK_TSV" "$PIN_TSV" "$REV_TSV"' EXIT

echo "== stack-lock: $(basename "$STACK_DIR") (dry-run$([ "$WRITE" = 1 ] && echo ' OFF — WRITING'))"

echo "-- MODEL_MAP provenance --"
for e in "${MODEL_MAP[@]:-}"; do
  IFS='|' read -r rel url sha <<<"$e"
  [ -z "${rel:-}" ] && continue
  case "$(host_of "$url")" in
    *huggingface.co)
      # one authed HEAD yields both the file sha256 (X-Linked-Etag) and the
      # commit the floating ref resolved to (X-Repo-Commit).
      hdrs="$(curl -sIL --max-time 30 -H "Authorization: Bearer $HF_TOKEN" "$url" 2>/dev/null || true)"
      etag="$(printf '%s' "$hdrs"   | awk 'tolower($1)=="x-linked-etag:"{gsub(/[\r"]/,"",$2);print $2}' | tail -n1)"
      commit="$(printf '%s' "$hdrs" | awk 'tolower($1)=="x-repo-commit:"{gsub(/[\r"]/,"",$2);print $2}' | tail -n1)"
      # sha256
      if is_sha256 "${sha:-}"; then printf '  [have] %s\n' "$rel"
      elif is_sha256 "${etag:-}"; then printf '  [lock] %s  sha256:%s\n' "$rel" "$etag"; printf '%s\t%s\n' "$rel" "$etag" >>"$LOCK_TSV"
      else printf '  [miss] %s  (no sha256 etag from HF)\n' "$rel"; fi
      # revision pin (rewrite floating /resolve/main|master/ -> /resolve/<commit>/)
      if [ "$PIN_HFREV" = 1 ]; then
        case "$url" in
          */resolve/main/*|*/resolve/master/*)
            if [ "${#commit}" -eq 40 ] && is_hex "${commit:-}"; then
              newurl="$(printf '%s' "$url" | sed -E "s#/resolve/(main|master)/#/resolve/${commit}/#")"
              printf '  [rev ] %s  -> /resolve/%s/\n' "$rel" "${commit:0:12}"
              printf '%s\t%s\n' "$rel" "$newurl" >>"$REV_TSV"
            else printf '  [rev?] %s  (no X-Repo-Commit header; cannot pin revision)\n' "$rel"; fi ;;
        esac
      fi ;;
    *)
      if is_sha256 "${sha:-}"; then printf '  [have] %s\n' "$rel"
      else printf '  [skip] %s  (non-HF url; sha256 not auto-derivable)\n' "$rel"; fi ;;
  esac
done

if [ "$PIN_NODES" = 1 ]; then
  echo "-- NODE_MAP pins --"
  for e in "${NODE_MAP[@]:-}"; do
    IFS='|' read -r url pin folder _extra <<<"$e"
    [ -z "${url:-}" ] && continue
    if [ -n "${pin:-}" ]; then printf '  [have] %s @ %s\n' "${folder:-$url}" "${pin:0:12}"; continue; fi
    head_sha="$(git ls-remote "$(gh_authed "$url")" HEAD 2>/dev/null | awk 'NR==1{print $1}')"
    if is_hex "${head_sha:-}" && [ -n "${head_sha:-}" ]; then
      printf '  [pin ] %s @ %s\n' "${folder:-$url}" "$head_sha"; printf '%s\t%s\n' "$folder" "$head_sha" >>"$PIN_TSV"
    else printf '  [miss] %s (could not resolve HEAD)\n' "${folder:-$url}"; fi
  done
fi

nlock=$(wc -l <"$LOCK_TSV"); npin=$(wc -l <"$PIN_TSV"); nrev=$(wc -l <"$REV_TSV")
echo "-- proposed: ${nlock} model sha256, ${nrev} HF revision pin(s), ${npin} node pin(s)"

if [ "$WRITE" != 1 ]; then
  echo "(dry-run — re-run with --write to apply)"
  exit 0
fi
[ "$nlock" -eq 0 ] && [ "$npin" -eq 0 ] && [ "$nrev" -eq 0 ] && { echo "nothing to write"; exit 0; }

cp -p "$CFG" "$CFG.bak"
LOCK_TSV="$LOCK_TSV" PIN_TSV="$PIN_TSV" REV_TSV="$REV_TSV" python3 - "$CFG" <<'PY'
import os, re, sys
cfg = sys.argv[1]
def load(fn):
    m = {}
    with open(fn) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line: continue
            k, v = line.split("\t", 1)
            m[k] = v
    return m
model_sha = load(os.environ["LOCK_TSV"])     # rel-path -> sha256
node_pin  = load(os.environ["PIN_TSV"])      # folder   -> commit sha
model_rev = load(os.environ["REV_TSV"])      # rel-path -> revision-pinned url

with open(cfg) as fh:
    lines = fh.readlines()

ENTRY = re.compile(r'^(\s*")([^"]*)(".*)$')   # indent+quote, inner, rest(comment/comma)
block = None  # 'MODEL_MAP' | 'NODE_MAP' | None
out = []
for ln in lines:
    s = ln.rstrip("\n")
    if re.match(r'^MODEL_MAP=\(', s):   block = 'MODEL_MAP'
    elif re.match(r'^NODE_MAP=\(', s):  block = 'NODE_MAP'
    elif block and re.match(r'^\)', s): block = None
    m = ENTRY.match(s) if block else None
    if m:
        inner = m.group(2)
        fields = inner.split("|")
        changed = False
        if block == 'MODEL_MAP' and len(fields) >= 2:
            rel = fields[0]
            if rel in model_rev and fields[1] != model_rev[rel]:
                fields[1] = model_rev[rel]; changed = True
            if rel in model_sha:
                while len(fields) < 3: fields.append("")
                if not re.fullmatch(r'[0-9a-fA-F]{64}', fields[2] or ""):
                    fields[2] = model_sha[rel]; changed = True
        elif block == 'NODE_MAP' and len(fields) >= 3:
            folder = fields[2]
            if folder in node_pin and not (fields[1] or "").strip():
                fields[1] = node_pin[folder]; changed = True
        if changed:
            out.append(f"{m.group(1)}{'|'.join(fields)}{m.group(3)}\n"); continue
    out.append(ln)

with open(cfg, "w") as fh:
    fh.writelines(out)
print(f"  wrote {len(model_sha)} model sha256 + {len(model_rev)} HF revision pin(s) + {len(node_pin)} node pin(s) into {cfg}")
print(f"  backup: {cfg}.bak")
PY
echo "Done. Re-run preflight-stack.sh --strict to confirm purity."
