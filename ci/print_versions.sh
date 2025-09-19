#!/usr/bin/env bash
set -euo pipefail
echo "aws: $(aws --version 2>&1 | head -n1)"
echo "tf : $(terraform -version | head -n1)"
echo "jq : $(jq --version)"
