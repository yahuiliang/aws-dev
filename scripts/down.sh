#!/usr/bin/env bash
# 销毁 Spot 实例（数据盘默认保留）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

cd "$TF_DIR"

echo "将销毁 Spot 实例，持久化 EBS 数据盘会保留。"
read -r -p "确认? [y/N] " ans
case "$ans" in
  y|Y) ;;
  *) exit 0 ;;
esac

terraform destroy -target=aws_spot_instance_request.dev \
  -target=aws_volume_attachment.data \
  -auto-approve

echo "实例已销毁。数据仍在 EBS 卷上，运行 ./scripts/up.sh 可重新挂载。"
