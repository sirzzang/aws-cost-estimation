#!/usr/bin/env bash
# prompt-hint.sh — UserPromptSubmit hook. Reads the prompt from stdin and emits
# a single reminder line if a risky provisioning keyword is detected.
# Never blocks: always exit 0.

set +e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$ROOT_DIR/cache"

prompt="$(cat 2>/dev/null || true)"

# Risky keywords (loose; keep regex anchored on whole-token matches when possible).
if printf "%s" "$prompt" \
  | grep -E -q '(terraform[[:space:]]+(apply|destroy)|cloudformation[[:space:]]+(create-stack|update-stack|deploy)|cdk[[:space:]]+deploy|eksctl[[:space:]]+create|(\./)?(install|provision|bootstrap)\.sh)'; then
  daily=""
  for f in "$CACHE_DIR"/audit-*.json; do
    [[ -f "$f" ]] || continue
    daily="$(jq -r '.daily_usd // empty' "$f" 2>/dev/null)"
    [[ -n "$daily" ]] && break
  done
  if [[ -n "$daily" ]]; then
    printf "[aws-cost] 💡 실행 전 /aws-cost estimate 권장. 마지막 audit: 일 추정 \$%s.\n" "$daily"
  else
    printf "[aws-cost] 💡 실행 전 /aws-cost estimate 권장.\n"
  fi
fi

exit 0
