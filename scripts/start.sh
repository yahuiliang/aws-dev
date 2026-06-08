#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
cd "$TF_DIR"

ID=$(terraform output -raw instance_id)
aws ec2 start-instances --instance-ids "$ID" --output text
echo "实例 $ID 正在启动，稍后用 ./scripts/info.sh 查看新 IP"
