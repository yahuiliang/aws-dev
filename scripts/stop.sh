#!/usr/bin/env bash
# 不用时停止实例省 Spot 费（EBS 仍计费，默认 16GB 约 $1.3/月）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
cd "$TF_DIR"

ID=$(terraform output -raw instance_id)
aws ec2 stop-instances --instance-ids "$ID" --output text
echo "实例 $ID 正在停止..."
