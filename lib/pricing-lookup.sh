#!/usr/bin/env bash
# Look up hourly USD rates from prices/seoul-cheatsheet.json (ap-northeast-2 baseline).
# Usage:
#   pricing-lookup.sh ec2 <instance_type>
#   pricing-lookup.sh eks_control_plane
#   pricing-lookup.sh rds <instance_class>           # mysql single-AZ baseline
#   pricing-lookup.sh nat_gateway
#   pricing-lookup.sh elb <alb|nlb|classic>
#   pricing-lookup.sh ebs_hourly <gp3|gp2|io2|st1|sc1> <gb>
# Stdout: hourly USD as a decimal number, or empty + exit 1 if not found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHEATSHEET="${AWS_COST_CHEATSHEET:-$SCRIPT_DIR/../prices/seoul-cheatsheet.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "pricing-lookup.sh: jq required but not installed" >&2
  exit 127
fi

if [[ ! -f "$CHEATSHEET" ]]; then
  echo "pricing-lookup.sh: cheatsheet not found at $CHEATSHEET" >&2
  exit 1
fi

_q() { jq -r "$1" "$CHEATSHEET"; }

ec2() {
  local t="$1"
  local v
  v=$(jq -r --arg t "$t" '.ec2_linux_hourly[$t] // empty' "$CHEATSHEET")
  [[ -n "$v" ]] || return 1
  printf "%s" "$v"
}

eks_control_plane() {
  _q '.eks_hourly.control_plane // empty'
}

rds() {
  local class="$1"
  local v
  v=$(jq -r --arg k "${class}_mysql_singleaz" '.rds_hourly[$k] // empty' "$CHEATSHEET")
  [[ -n "$v" ]] || return 1
  printf "%s" "$v"
}

nat_gateway() {
  _q '.nat_gateway_hourly // empty'
}

elb() {
  local t="$1"
  local v
  v=$(jq -r --arg t "$t" '.elb_hourly[$t] // empty' "$CHEATSHEET")
  [[ -n "$v" ]] || return 1
  printf "%s" "$v"
}

ebs_hourly() {
  local type="$1" gb="$2"
  local monthly
  monthly=$(jq -r --arg t "$type" '.ebs_per_gb_month[$t] // empty' "$CHEATSHEET")
  [[ -n "$monthly" ]] || return 1
  awk -v m="$monthly" -v g="$gb" 'BEGIN{ printf "%.6f", m * g / 730 }'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    ec2)               ec2 "$@" ;;
    eks_control_plane) eks_control_plane ;;
    rds)               rds "$@" ;;
    nat_gateway)       nat_gateway ;;
    elb)               elb "$@" ;;
    ebs_hourly)        ebs_hourly "$@" ;;
    *)
      echo "usage: $0 {ec2 <type>|eks_control_plane|rds <class>|nat_gateway|elb <type>|ebs_hourly <type> <gb>}" >&2
      exit 2
      ;;
  esac
fi
