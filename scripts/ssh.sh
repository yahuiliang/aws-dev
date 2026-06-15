#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
# shellcheck source=lib/ssh_connect.sh
source "$ROOT/scripts/lib/ssh_connect.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"

cd "$TF_DIR"

IP=$(terraform output -raw public_ip 2>/dev/null || true)
USER=$(tfvar dev_username dev)

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "未找到运行中的实例，请先 make up"
  exit 1
fi

build_ssh_opts
echo "连接 $USER@$IP ..."
exec ssh "${SSH_OPTS[@]}" "$USER@$IP" "$@"
