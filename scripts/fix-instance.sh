#!/usr/bin/env bash
# setup 异常时，SSH 以 dev 重跑 bootstrap 并等待就绪
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"

cd "$TF_DIR"
IP=$(terraform output -raw public_ip 2>/dev/null || true)
USER=$(tfvar dev_username dev)
PUB_PATH=$(tfvar ssh_public_key_path "~/.ssh/id_rsa.pub")
PUB_PATH="${PUB_PATH/#\~/$HOME}"
KEY="${PUB_PATH%.pub}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
[[ -f "$KEY" ]] && SSH_OPTS+=(-i "$KEY")

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "未找到运行中的实例，请先 make up 或 make start"
  exit 1
fi

echo "→ 重跑 dev-box-setup ($USER@$IP)..."
if ! ssh "${SSH_OPTS[@]}" "$USER@$IP" 'sudo /usr/local/bin/dev-box-setup.sh'; then
  echo "失败：dev 用户无法 SSH 或 setup 脚本不存在，试 make restart"
  exit 1
fi

echo "→ 等待环境就绪..."
"$ROOT/scripts/wait-ready.sh"

echo "修复完成。运行 make cursor 后连接 aws-vibe-dev"
