#!/usr/bin/env bash
# estimate.sh — pre-provisioning cost estimate for an IaC directory.
# Dispatches to terraform/infracost path or LLM-fallback path based on classify.sh.
#
# Usage:
#   estimate.sh [path]    # path defaults to $PWD

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHEATSHEET="$ROOT_DIR/prices/seoul-cheatsheet.json"
CLASSIFY="$SCRIPT_DIR/classify.sh"
INFRACOST_WRAP="$SCRIPT_DIR/infracost-wrap.sh"
FORMAT="$SCRIPT_DIR/format.sh"

dir="${1:-$PWD}"
dir="$(cd "$dir" && pwd)"

kind="$("$CLASSIFY" "$dir")"

print_terraform_breakdown() {
  local json="$1"
  local hourly monthly
  hourly="$(jq -r '.totalHourlyCost // "0"' <<< "$json")"
  monthly="$(jq -r '.totalMonthlyCost // "0"' <<< "$json")"
  printf "📦 estimate — terraform — %s\n" "$dir"
  "$FORMAT" hourly_table "$hourly"
  printf "── (참고) infracost monthly: USD \$%.2f\n" "$monthly"
  printf "주요 비용 항목:\n"
  jq -r '
    [(.projects // [])[].breakdown.resources[]?
     | {n: .name, h: (.hourlyCost // "0" | tonumber)}]
    | sort_by(-.h) | .[0:8][]
    | "  • \(.n): $\(.h)/h"
  ' <<< "$json" || true
  "$FORMAT" footer
}

print_fallback_header() {
  local kind="$1"
  printf "[LLM-FALLBACK] estimate — %s — %s\n" "$kind" "$dir"
  printf "infracost로 직접 견적이 불가능한 디렉토리입니다. Claude가 다음 절차로 견적을 산출합니다:\n"
  printf "  1) 아래 IaC 파일을 읽고 리소스 인벤토리 추출 (인스턴스 타입, 갯수, 옵션).\n"
  printf "  2) %s 또는 'aws pricing get-products'로 단가 조회.\n" "$CHEATSHEET"
  printf "  3) lib/format.sh hourly_table <USD/h> 으로 1h/24h/1주/30일 표 출력.\n"
  printf "  4) 출력 마지막에 다음 disclaimer 1줄을 반드시 포함:\n"
  printf "     '⚠️ 본 견적은 LLM 추론 + 단가 합산 결과이며 ±30%% 오차 가능. 정확도가 필요하면 infracost 사용 권장.'\n"
  printf "\n--- IaC 파일 목록 ---\n"
  ( cd "$dir" && find . -maxdepth 3 -type f \
      \( -name '*.tf' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.sh' \) \
      | sort )
  printf "\n--- 가격표(JSON) ---\n%s\n" "$CHEATSHEET"
  "$FORMAT" footer
}

case "$kind" in
  terraform)
    if json="$("$INFRACOST_WRAP" "$dir" 2>/dev/null)"; then
      print_terraform_breakdown "$json"
      exit 0
    else
      rc=$?
      printf "[infracost path failed rc=%d, falling back]\n\n" "$rc" >&2
      print_fallback_header "terraform-fallback"
      exit 0
    fi
    ;;
  cloudformation|shell-iac)
    print_fallback_header "$kind"
    exit 0
    ;;
  none)
    printf "estimate.sh: %s 에 IaC 신호가 없음 (terraform / cloudformation / shell 모두 미감지)\n" "$dir"
    exit 0
    ;;
  *)
    printf "estimate.sh: classify 결과 알 수 없음: %s\n" "$kind" >&2
    exit 1
    ;;
esac
