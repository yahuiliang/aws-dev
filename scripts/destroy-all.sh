#!/usr/bin/env bash
# 销毁全部 Terraform 资源（含数据盘）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"
PROJECT=$(tfvar project_name vibe-dev)

cd "$TF_DIR"

echo "将销毁 ${PROJECT} 全部资源（含 EBS 数据盘，代码不可恢复）。"
echo ""
read -r -p "确认全部删除? [y/N] " ans
case "$ans" in
  y|Y) ;;
  *) exit 0 ;;
esac

terraform destroy -auto-approve

echo "全部资源已销毁。"
