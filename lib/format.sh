#!/usr/bin/env bash
# Currency / table formatting helpers for /aws-cost outputs.
# Convention: USD primary, KRW = USD * KRW_PER_USD (default 1400).
# Override with: KRW_PER_USD=1380 ./format.sh ...
#
# Usage:
#   format.sh usd_krw <usd_float>
#       → "USD $X.XX / KRW Y,YYY"
#   format.sh hourly_table <usd_per_hour>
#       → 4 lines: 시간당 / 24h / 1주 / 30일
#   format.sh footer
#       → environment / disclaimer line

set -euo pipefail

KRW_PER_USD="${KRW_PER_USD:-1400}"

add_thousands() {
  local n="$1"
  local sign=""
  if [[ "$n" == -* ]]; then
    sign="-"
    n="${n#-}"
  fi
  printf "%s%s" "$sign" "$(echo "$n" | rev | sed 's/[0-9]\{3\}/&,/g' | rev | sed 's/^,//')"
}

usd_krw() {
  local usd="$1"
  local krw
  krw=$(awk -v u="$usd" -v r="$KRW_PER_USD" 'BEGIN { printf "%.0f", u * r }')
  local krw_fmt
  krw_fmt="$(add_thousands "$krw")"
  printf 'USD $%.2f / KRW %s\n' "$usd" "$krw_fmt"
}

hourly_table() {
  local h="$1"
  printf "── 시간당   %s\n" "$(usd_krw "$h")"
  printf "── 24h     %s\n"  "$(usd_krw "$(awk -v h="$h" 'BEGIN{printf "%.4f", h*24}')")"
  printf "── 1주     %s\n"  "$(usd_krw "$(awk -v h="$h" 'BEGIN{printf "%.4f", h*24*7}')")"
  printf "── 30일    %s\n"  "$(usd_krw "$(awk -v h="$h" 'BEGIN{printf "%.4f", h*24*30}')")"
}

print_footer() {
  printf "환율 가정: %s KRW/USD. ap-northeast-2 기준 추정값.\n" "$KRW_PER_USD"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    usd_krw)      usd_krw "$@" ;;
    hourly_table) hourly_table "$@" ;;
    footer)       print_footer ;;
    *)
      echo "usage: $0 {usd_krw <usd> | hourly_table <usd_per_hour> | footer}" >&2
      exit 2
      ;;
  esac
fi
