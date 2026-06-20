#!/usr/bin/env bash
# 等待实例 SSH 可用且 dev-box setup 完成
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
PUBLIC_IP=$(terraform output -raw public_ip 2>/dev/null | tr -d '[:space:]' || true)
USER=$(tfvar dev_username dev)
build_ssh_opts -o BatchMode=yes -o ConnectTimeout=10

READY_SCRIPT=$(remote_setup_ready_script)
BLOCK_SSH=$(tfvar block_ssh_until_ready true)

if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "null" ]]; then
  echo "未找到实例 IP"
  exit 1
fi

ssh_try() {
  ssh "${SSH_OPTS[@]}" "$USER@$PUBLIC_IP" "$@" 2>/dev/null
}

is_ready() {
  if [[ "$BLOCK_SSH" == "true" ]]; then
    # ForceCommand gate：setup-complete 前 SSH 会失败
    ssh_try true
  else
    ssh_try bash -s <<< "$READY_SCRIPT"
  fi
}

printf '→ 等待环境就绪 (%s@%s，最多 %ss)...\n' "$USER" "$PUBLIC_IP" "$TIMEOUT"
start=$(date +%s)
while true; do
  if is_ready; then
    elapsed=$(( $(date +%s) - start ))
    echo "✓ 环境就绪（${elapsed}s）"
    exit 0
  fi
  elapsed=$(( $(date +%s) - start ))
  if (( elapsed >= TIMEOUT )); then
    printf '超时。查看进度: ssh %s@%s '\''sudo journalctl -t dev-box-setup -f'\''\n' "$USER" "$PUBLIC_IP"
    exit 1
  fi
  sleep "$POLL"
done
