#!/usr/bin/env bash
# infracost-wrap.sh — run terraform plan (read-only) and infracost breakdown.
# Stdout: JSON with hourly + monthly USD totals.
# Exit codes:
#   0 — success
#   2 — infracost not installed (caller falls back to LLM path)
#   3 — terraform init/plan failed (caller falls back to LLM path)
#   4 — infracost run failed
#
# Usage:
#   infracost-wrap.sh <terraform_dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$ROOT_DIR/cache"
TTL_SECONDS=$(( 60 * 60 ))  # 1h

dir="${1:-}"
if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "infracost-wrap.sh: usage: $0 <terraform_dir>" >&2
  exit 64
fi
dir="$(cd "$dir" && pwd)"

mkdir -p "$CACHE_DIR"

# Cache key: sha256 of all *.tf, *.tfvars, *.tf.json contents.
cache_key() {
  ( cd "$dir" && find . -maxdepth 2 -type f \( -name '*.tf' -o -name '*.tfvars' -o -name '*.tf.json' \) -print0 \
    | sort -z \
    | xargs -0 cat 2>/dev/null \
    | shasum -a 256 \
    | awk '{print $1}' )
}

if ! command -v infracost >/dev/null 2>&1; then
  cat >&2 <<'EOM'
[infracost-wrap] infracost not installed. Install with:
  brew install infracost
  infracost auth login
Falling back to LLM-based estimation path.
EOM
  exit 2
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "[infracost-wrap] terraform CLI not found in PATH" >&2
  exit 3
fi

key="$(cache_key)"
cache_file="$CACHE_DIR/infracost-$key.json"
if [[ -f "$cache_file" ]]; then
  mtime="$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)"
  now="$(date -u +%s)"
  if (( now - mtime <= TTL_SECONDS )); then
    cat "$cache_file"
    exit 0
  fi
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

(
  cd "$dir"
  terraform init -backend=false -input=false -no-color >"$tmpdir/init.log" 2>&1 || {
    echo "[infracost-wrap] terraform init failed; see $tmpdir/init.log (kept for inspection)" >&2
    cp "$tmpdir/init.log" "$CACHE_DIR/last-init-error.log" 2>/dev/null || true
    exit 3
  }
  terraform plan -refresh=false -input=false -no-color -out="$tmpdir/plan.tfplan" >"$tmpdir/plan.log" 2>&1 || {
    echo "[infracost-wrap] terraform plan failed; see $tmpdir/plan.log" >&2
    cp "$tmpdir/plan.log" "$CACHE_DIR/last-plan-error.log" 2>/dev/null || true
    exit 3
  }
)

infracost breakdown --path "$tmpdir/plan.tfplan" --format json --no-color > "$cache_file" 2>"$tmpdir/ic.log" || {
  echo "[infracost-wrap] infracost breakdown failed; see $tmpdir/ic.log" >&2
  cp "$tmpdir/ic.log" "$CACHE_DIR/last-infracost-error.log" 2>/dev/null || true
  rm -f "$cache_file"
  exit 4
}

cat "$cache_file"
