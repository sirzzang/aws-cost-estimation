#!/usr/bin/env bash
# Shell-IaC fixture: invokes aws CLI directly.
set -euo pipefail
echo "Provisioning..."
aws sts get-caller-identity
