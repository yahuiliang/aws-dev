#!/usr/bin/env bash
# Spot 被回收或实例异常时，强制重建
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

cd "$TF_DIR"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"
ensure_dev_rdp_password

terraform taint -allow-missing aws_spot_instance_request.dev 2>/dev/null || true

# shellcheck source=lib/spot_apply.sh
source "$ROOT/scripts/lib/spot_apply.sh"
spot_apply_with_fallback "$TF_DIR"

echo "实例已重建，setup 在后台运行；完成前 SSH 被门禁拦截。"
echo "需要确认就绪时: make wait-ready"
echo ""
"$ROOT/scripts/info.sh"
