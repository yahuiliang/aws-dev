#!/usr/bin/env bash
# 运行单元测试（需要 bats: brew install bats-core）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "未找到 bats。安装: brew install bats-core"
  exit 1
fi

echo "→ 运行单元测试..."
bats "$ROOT/tests/"*.bats
