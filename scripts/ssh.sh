#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

cd "$TF_DIR"

IP=$(terraform output -raw public_ip 2>/dev/null || true)

tfvar() {
  local key="$1" default="${2:-}"
  local val
  val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" terraform.tfvars 2>/dev/null | head -1 \
    | sed -n 's/^[[:space:]]*[^=]*=[[:space:]]*"\([^"]*\)".*/\1/p') || true
  echo "${val:-$default}"
}

USER=$(tfvar dev_username dev)

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "未找到运行中的实例，请先 make up"
  exit 1
fi

echo "连接 $USER@$IP ..."
exec ssh -o StrictHostKeyChecking=accept-new "$USER@$IP" "$@"
