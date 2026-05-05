#!/usr/bin/env bash
# audit.sh — list active AWS resources and compute LaunchTime-based accumulated estimates.
# Read-only: only describe-* / list-* / get-caller-identity / pricing get-products.
#
# Usage:
#   audit.sh                # full audit, prints table + writes cache
#   audit.sh --quiet        # only writes cache, no stdout
#   audit.sh --from-cache   # prints cached result if fresh (<15min), else exit 1
#
# Cache: cache/audit-<account_id>.json (TTL 15 minutes).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$ROOT_DIR/cache"
PRICING="$SCRIPT_DIR/pricing-lookup.sh"
FORMAT="$SCRIPT_DIR/format.sh"
TTL_SECONDS=900  # 15 min
DAILY_WARN=5
ACCUM_WARN=20

mkdir -p "$CACHE_DIR"

QUIET=0
FROM_CACHE=0
for arg in "$@"; do
  case "$arg" in
    --quiet)      QUIET=1 ;;
    --from-cache) FROM_CACHE=1 ;;
  esac
done

# Convert ISO 8601 timestamp (UTC, possibly fractional + Z or +00:00) to epoch seconds.
iso_to_epoch() {
  local ts="$1"
  python3 - <<PY 2>/dev/null
import datetime, sys
ts = "$ts"
ts = ts.replace("Z", "+00:00")
# trim fractional > 6 digits
import re
ts = re.sub(r"\.(\d{6})\d+", r".\1", ts)
try:
    print(int(datetime.datetime.fromisoformat(ts).timestamp()))
except Exception:
    print("")
PY
}

now_epoch() { date -u +%s; }

hours_since() {
  local ts="$1"
  local then
  then="$(iso_to_epoch "$ts")"
  [[ -n "$then" ]] || { echo 0; return; }
  awk -v n="$(now_epoch)" -v t="$then" 'BEGIN{ d=n-t; if(d<0)d=0; printf "%.2f", d/3600 }'
}

add() { awk -v a="$1" -v b="$2" 'BEGIN{ printf "%.4f", a+b }'; }
gte() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a>=b) }'; }

# Helpers to call AWS (read-only). Each emits raw JSON or {} on failure.
aws_json() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "{}"
    return
  fi
  aws "$@" --output json 2>/dev/null || echo "{}"
}

audit_account() {
  local cli_id_json
  cli_id_json="$(aws_json sts get-caller-identity)"
  jq -r '.Account // ""' <<< "$cli_id_json"
}

audit_region() {
  local region
  region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  if [[ -z "$region" ]]; then
    region="$(aws configure get region 2>/dev/null || echo "ap-northeast-2")"
  fi
  printf "%s" "$region"
}

# Parse JSON inputs and return resource lines as TSV: type<TAB>id<TAB>label<TAB>launchTimeISO<TAB>hourlyUSD
parse_ec2() {
  local json="$1"
  jq -r '
    (.Reservations // [])[] .Instances[]?
    | [
        "ec2",
        .InstanceId,
        .InstanceType,
        .LaunchTime
      ] | @tsv
  ' <<< "$json"
}

parse_eks() {
  local clusters_json="$1"  # output of: aws eks list-clusters
  jq -r '(.clusters // [])[]' <<< "$clusters_json" | while read -r name; do
    [[ -n "$name" ]] || continue
    local desc
    desc="$(aws_json eks describe-cluster --name "$name")"
    local created
    created="$(jq -r '.cluster.createdAt // ""' <<< "$desc")"
    printf "eks\t%s\tcontrol-plane\t%s\n" "$name" "$created"
  done
}

parse_rds() {
  local json="$1"
  jq -r '
    (.DBInstances // [])[]
    | select(.DBInstanceStatus=="available")
    | [
        "rds",
        .DBInstanceIdentifier,
        .DBInstanceClass,
        .InstanceCreateTime
      ] | @tsv
  ' <<< "$json"
}

parse_nat() {
  local json="$1"
  jq -r '
    (.NatGateways // [])[]
    | select(.State=="available")
    | [
        "nat",
        .NatGatewayId,
        "nat-gateway",
        .CreateTime
      ] | @tsv
  ' <<< "$json"
}

parse_elb() {
  local json="$1"
  jq -r '
    (.LoadBalancers // [])[]
    | [
        "elb",
        .LoadBalancerArn,
        (.Type // "alb"),
        .CreatedTime
      ] | @tsv
  ' <<< "$json"
}

parse_ebs() {
  local json="$1"
  jq -r '
    (.Volumes // [])[]
    | select(.State=="in-use")
    | select(.Size >= 100)
    | [
        "ebs",
        .VolumeId,
        (.VolumeType + "@" + (.Size|tostring) + "GB"),
        .CreateTime
      ] | @tsv
  ' <<< "$json"
}

# Resolve hourly USD given (type, label).
resolve_hourly() {
  local rtype="$1" label="$2"
  case "$rtype" in
    ec2)  "$PRICING" ec2 "$label" 2>/dev/null || echo "" ;;
    eks)  "$PRICING" eks_control_plane 2>/dev/null || echo "" ;;
    rds)  "$PRICING" rds "$label" 2>/dev/null || echo "" ;;
    nat)  "$PRICING" nat_gateway 2>/dev/null || echo "" ;;
    elb)  local kind="${label,,}"; case "$kind" in network) kind="nlb" ;; application) kind="alb" ;; classic) kind="classic" ;; esac; "$PRICING" elb "$kind" 2>/dev/null || echo "" ;;
    ebs)  local typ="${label%@*}" size="${label##*@}"; size="${size%GB}"; "$PRICING" ebs_hourly "$typ" "$size" 2>/dev/null || echo "" ;;
    *)    echo "" ;;
  esac
}

# ── Main flow ─────────────────────────────────────────────────────────────────

main_audit() {
  local acct region as_of
  acct="$(audit_account)"
  region="$(audit_region)"
  as_of="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -z "$acct" ]]; then
    echo "audit.sh: aws sts get-caller-identity failed (no credentials?)" >&2
    return 1
  fi

  local cache_file="$CACHE_DIR/audit-$acct.json"

  # Gather raw responses.
  local ec2_json eks_json rds_json nat_json elb_json ebs_json
  ec2_json="$(aws_json ec2 describe-instances --filters Name=instance-state-name,Values=running --region "$region")"
  eks_json="$(aws_json eks list-clusters --region "$region")"
  rds_json="$(aws_json rds describe-db-instances --region "$region")"
  nat_json="$(aws_json ec2 describe-nat-gateways --filter Name=state,Values=available --region "$region")"
  elb_json="$(aws_json elbv2 describe-load-balancers --region "$region")"
  ebs_json="$(aws_json ec2 describe-volumes --filters Name=status,Values=in-use --region "$region")"

  # Build resource list TSV.
  local tsv
  tsv="$(
    parse_ec2 "$ec2_json"
    parse_eks "$eks_json"
    parse_rds "$rds_json"
    parse_nat "$nat_json"
    parse_elb "$elb_json"
    parse_ebs "$ebs_json"
  )"

  # Compute per-resource hourly + accumulated.
  local resources_json="[]"
  local total_hourly=0
  local total_accumulated=0

  if [[ -n "$tsv" ]]; then
    while IFS=$'\t' read -r rtype rid label ts; do
      [[ -n "$rtype" ]] || continue
      local hourly hours accum
      hourly="$(resolve_hourly "$rtype" "$label")"
      [[ -z "$hourly" ]] && hourly=0
      hours="$(hours_since "$ts")"
      accum="$(awk -v h="$hourly" -v t="$hours" 'BEGIN{printf "%.4f", h*t}')"
      total_hourly="$(add "$total_hourly" "$hourly")"
      total_accumulated="$(add "$total_accumulated" "$accum")"
      resources_json="$(jq --arg rtype "$rtype" --arg rid "$rid" --arg label "$label" --arg ts "$ts" \
                          --argjson hourly "$hourly" --argjson hours "$hours" --argjson accum "$accum" \
                         '. + [{type:$rtype,id:$rid,label:$label,launch_time:$ts,hourly_usd:$hourly,hours:$hours,accumulated_usd:$accum}]' <<< "$resources_json")"
    done <<< "$tsv"
  fi

  local daily
  daily="$(awk -v h="$total_hourly" 'BEGIN{printf "%.2f", h*24}')"

  # Warnings.
  local warns="[]"
  if gte "$daily" "$DAILY_WARN"; then
    warns="$(jq '. + ["daily estimate exceeds $5"]' <<< "$warns")"
  fi
  if gte "$total_accumulated" "$ACCUM_WARN"; then
    warns="$(jq '. + ["accumulated estimate exceeds $20"]' <<< "$warns")"
  fi

  local result
  result="$(jq -n \
              --arg as_of "$as_of" --arg acct "$acct" --arg region "$region" \
              --argjson resources "$resources_json" \
              --argjson hourly "$total_hourly" \
              --argjson daily "$daily" \
              --argjson accum "$total_accumulated" \
              --argjson warns "$warns" \
              '{as_of:$as_of, account_id:$acct, region:$region, hourly_usd:$hourly, daily_usd:$daily, accumulated_usd:$accum, resources:$resources, warnings:$warns}')"

  printf "%s\n" "$result" > "$cache_file"

  if (( QUIET == 0 )); then
    render_audit "$result"
  fi
}

render_audit() {
  local result="$1"
  local as_of acct region daily accum n warns
  as_of="$(jq -r '.as_of' <<< "$result")"
  acct="$(jq -r '.account_id' <<< "$result")"
  region="$(jq -r '.region' <<< "$result")"
  daily="$(jq -r '.daily_usd' <<< "$result")"
  accum="$(jq -r '.accumulated_usd' <<< "$result")"
  n="$(jq -r '.resources | length' <<< "$result")"
  warns="$(jq -r '.warnings | length' <<< "$result")"

  local warn_marker=""
  (( warns > 0 )) && warn_marker="  ⚠️"

  printf "💰 Account %s — region %s — as of %s%s\n" "$acct" "$region" "$as_of" "$warn_marker"
  printf "활성 리소스 %d개  /  일일 추정 %s  /  누적 추정 %s\n" \
         "$n" "$("$FORMAT" usd_krw "$daily")" "$("$FORMAT" usd_krw "$accum")"
  printf "───────────────────────────\n"

  jq -r '.resources[]
        | "  • \(.type)\t\(.id)\t\(.label)\t\(.hours|tostring)h\t$\(.hourly_usd)/h\t누적 $\(.accumulated_usd)"' <<< "$result" \
    | column -t -s $'\t' || jq -r '.resources[] | "  • \(.type) \(.id) \(.label) \(.hours)h $\(.hourly_usd)/h 누적 $\(.accumulated_usd)"' <<< "$result"

  printf "───────────────────────────\n"
  if (( warns > 0 )); then
    printf "삭제 예시 (직접 실행 필요):\n"
    jq -r '.resources[]
          | select(.accumulated_usd >= 1)
          | if .type=="ec2" then "  aws ec2 terminate-instances --instance-ids \(.id)"
            elif .type=="eks" then "  aws eks delete-cluster --name \(.id)"
            elif .type=="rds" then "  aws rds delete-db-instance --db-instance-identifier \(.id) --skip-final-snapshot"
            elif .type=="nat" then "  aws ec2 delete-nat-gateway --nat-gateway-id \(.id)"
            elif .type=="elb" then "  aws elbv2 delete-load-balancer --load-balancer-arn \(.id)"
            elif .type=="ebs" then "  aws ec2 delete-volume --volume-id \(.id)"
            else "" end' <<< "$result" | grep -v '^$' || true
  fi
  "$FORMAT" footer
}

main_from_cache() {
  local acct cache_file age
  acct="$(audit_account)"
  cache_file="$CACHE_DIR/audit-$acct.json"
  [[ -f "$cache_file" ]] || return 1
  local mtime now
  mtime="$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)"
  now="$(now_epoch)"
  age=$(( now - mtime ))
  if (( age > TTL_SECONDS )); then
    return 1
  fi
  render_audit "$(cat "$cache_file")"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if (( FROM_CACHE )); then
    main_from_cache
  else
    main_audit
  fi
fi
