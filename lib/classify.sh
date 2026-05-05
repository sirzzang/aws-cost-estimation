#!/usr/bin/env bash
# Classify an IaC directory by its primary content.
# Usage: classify.sh <path>
# Output (stdout, single token): terraform | cloudformation | shell-iac | none
# Exit: 0 always (best-effort classifier; never blocks caller).

set -euo pipefail
shopt -s nullglob

dir="${1:-.}"
if [[ ! -d "$dir" ]]; then
  echo "none"
  exit 0
fi

# 1) Terraform: any *.tf file present.
tf_files=("$dir"/*.tf)
if (( ${#tf_files[@]} > 0 )); then
  echo "terraform"
  exit 0
fi

# 2) CloudFormation: a YAML/JSON file with AWSTemplateFormatVersion or AWS::Resource:: marker.
for f in "$dir"/*.yaml "$dir"/*.yml "$dir"/*.json; do
  [[ -f "$f" ]] || continue
  if grep -q -E '(AWSTemplateFormatVersion|AWS::[A-Za-z]+::)' "$f" 2>/dev/null; then
    echo "cloudformation"
    exit 0
  fi
done

# 3) Shell-IaC: a *.sh referencing aws / terraform / cloudformation / eksctl.
for f in "$dir"/*.sh; do
  [[ -f "$f" ]] || continue
  if grep -q -E '(\baws\b|\bterraform\b|\bcloudformation\b|\beksctl\b)' "$f" 2>/dev/null; then
    echo "shell-iac"
    exit 0
  fi
done

echo "none"
