#!/usr/bin/env bash
set -euo pipefail

SSH_CONFIG="$HOME/.ssh/config"
if ! grep -q 'Host aws-vibe-dev' "$SSH_CONFIG" 2>/dev/null; then
  echo "未找到 Host aws-vibe-dev，请先运行 make cursor"
  exit 1
fi

echo "SSH 隧道已启动（Ctrl+C 退出）。RDP: 127.0.0.1:3389"
exec ssh -N aws-vibe-dev
