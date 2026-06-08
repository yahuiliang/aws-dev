#!/usr/bin/env bash
# 本地前置检查：AWS CLI、Terraform、jq
set -euo pipefail

check() {
  if command -v "$1" &>/dev/null; then
    echo "✓ $1 ($($1 --version 2>&1 | head -1))"
  else
    echo "✗ $1 未安装"
    MISSING=1
  fi
}

MISSING=0
check aws
check terraform
check jq
check ssh-keygen

if [[ "${MISSING:-0}" == 1 ]]; then
  echo ""
  echo "macOS 安装示例:"
  echo "  brew tap hashicorp/tap && brew install awscli jq hashicorp/tap/terraform"
  exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
  echo "✗ AWS 未登录，请运行: aws login"
  exit 1
fi

echo ""
echo "AWS 账号: $(aws sts get-caller-identity --query Account --output text)"
echo "本地环境 OK，可运行 make up"
