#!/usr/bin/env bash
# Spot 被回收或实例异常时，强制重建
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

cd "$TF_DIR"

terraform taint -allow-missing aws_spot_instance_request.dev 2>/dev/null || true
terraform apply -auto-approve

echo "→ 等待环境就绪..."
"$ROOT/scripts/wait-ready.sh"

echo "实例已重建。"
"$ROOT/scripts/info.sh"
