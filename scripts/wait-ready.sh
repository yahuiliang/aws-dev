#!/usr/bin/env bash
# 等待实例 SSH 可用且 dev-box setup 完成
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
TIMEOUT="${WAIT_READY_TIMEOUT:-600}"
POLL="${WAIT_READY_POLL:-15}"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"

cd "$TF_DIR"
IP=$(terraform output -raw public_ip 2>/dev/null || true)
USER=$(tfvar dev_username dev)
PUB_PATH=$(tfvar ssh_public_key_path "~/.ssh/id_rsa.pub")
PUB_PATH="${PUB_PATH/#\~/$HOME}"
KEY="${PUB_PATH%.pub}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[[ -f "$KEY" ]] && SSH_OPTS+=(-i "$KEY")

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "未找到实例 IP"
  exit 1
fi

ssh_try() {
  ssh "${SSH_OPTS[@]}" "$USER@$IP" "$@" 2>/dev/null
}

echo "→ 等待 SSH 可用 ($USER@$IP)..."
for _ in $(seq 1 40); do
  ssh_try true && break
  sleep 5
done
ssh_try true || { echo "SSH 连接超时"; exit 1; }

echo "→ 等待环境初始化（最多 ${TIMEOUT}s）..."
start=$(date +%s)
while true; do
  if ssh_try 'test -f /data/.initialized'; then
    elapsed=$(( $(date +%s) - start ))
    echo "✓ 环境就绪（${elapsed}s）"
    exit 0
  fi
  elapsed=$(( $(date +%s) - start ))
  if (( elapsed >= TIMEOUT )); then
    echo "超时。查看进度: ssh $USER@$IP 'sudo journalctl -t dev-box-setup -f'"
    exit 1
  fi
  echo "  仍在安装... ${elapsed}s"
  sleep "$POLL"
done
