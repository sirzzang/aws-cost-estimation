#!/usr/bin/env bash
# watch.sh — SessionStart hook entry point. ≤3s budget, exit 0 always.
# Outputs 0 / 1 / 2 lines based on:
#   (a) cwd has IaC signal? (classify != none)
#   (b) audit cache exists with daily_usd > 0?
#
# Designed to be silent in non-IaC directories with no active resources, so it
# never becomes background noise.

# Note: not setting -e so a single failure cannot block session start.
set -u
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib"
CACHE_DIR="$SCRIPT_DIR/cache"
TTL_SECONDS=900
START_EPOCH="$(date -u +%s)"

emit() { printf "%s\n" "$1"; }

# Hard timeout — don't block the session under any circumstance.
( sleep 3; kill -TERM $$ 2>/dev/null ) &
TIMEOUT_PID=$!
trap 'kill $TIMEOUT_PID 2>/dev/null' EXIT

# (a) classify cwd
kind="$("$LIB/classify.sh" "$PWD" 2>/dev/null || echo "none")"

# (b) check audit cache freshness for any account
audit_line=""
shopt -s nullglob
for f in "$CACHE_DIR"/audit-*.json; do
  [[ -f "$f" ]] || continue
  mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)"
  age=$(( START_EPOCH - mtime ))
  if (( age <= TTL_SECONDS )); then
    n="$(jq -r '.resources | length // 0' "$f" 2>/dev/null || echo 0)"
    daily="$(jq -r '.daily_usd // 0' "$f" 2>/dev/null || echo 0)"
    krw="$(awk -v u="$daily" 'BEGIN{printf "%.0f", u*1400}')"
    krw_fmt="$(echo "$krw" | rev | sed 's/[0-9]\{3\}/&,/g' | rev | sed 's/^,//')"
    if (( n > 0 )); then
      marker=""
      awk -v d="$daily" 'BEGIN{exit !(d>=5)}' && marker="⚠️ "
      audit_line="[aws-cost] ${marker}활성 리소스 ${n}개, 일일 추정 \$${daily} / KRW ${krw_fmt}  (자세히: /aws-cost audit)"
    fi
    break
  fi
done

# (a) line — only when IaC is in cwd
estimate_line=""
case "$kind" in
  terraform|cloudformation|shell-iac)
    estimate_line="[aws-cost] 📁 ${kind}: $(basename "$PWD") — /aws-cost estimate 실행 권장"
    ;;
esac

[[ -n "$estimate_line" ]] && emit "$estimate_line"
[[ -n "$audit_line"    ]] && emit "$audit_line"

exit 0
