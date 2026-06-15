#!/usr/bin/env bash
# 等待实例 SSH 可用且 dev-box setup 全部完成（含桌面/xrdp 等可选组件）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
TIMEOUT="${WAIT_READY_TIMEOUT:-1200}"
POLL="${WAIT_READY_POLL:-15}"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
# shellcheck source=lib/ready_check.sh
source "$ROOT/scripts/lib/ready_check.sh"
# shellcheck source=lib/ssh_connect.sh
source "$ROOT/scripts/lib/ssh_connect.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"

cd "$TF_DIR"
IP=$(terraform output -raw public_ip 2>/dev/null || true)
USER=$(tfvar dev_username dev)
build_ssh_opts -o BatchMode=yes -o ConnectTimeout=10

READY_SCRIPT=$(remote_setup_ready_script)

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

echo "→ 等待 setup 全部完成（最多 ${TIMEOUT}s，含桌面/xrdp 等）..."
start=$(date +%s)
while true; do
  if ssh_try bash -s <<< "$READY_SCRIPT"; then
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
