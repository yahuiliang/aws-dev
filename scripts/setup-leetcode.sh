#!/usr/bin/env bash
# 补装 / 修复 LeetCode 环境（本机执行会推到 EC2；实例上带 --on-instance）
set -euo pipefail

run_on_instance() {
  local dev_user="${1:-dev}"
  local lc_dir="/data/home/$dev_user/projects/leetcode"

  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  for lib in "$script_dir/lib/nvm-dev.sh" "$script_dir/nvm-dev.sh" /tmp/nvm-dev.sh; do
    if [[ -f "$lib" ]]; then
      # shellcheck source=/dev/null
      source "$lib"
      break
    fi
  done
  if ! declare -F dev_install_leetcode_cli >/dev/null; then
    echo "缺少 nvm-dev.sh"
    exit 1
  fi

  mkdir -p "$lc_dir"/{solutions,cache}

  if ! swapon --show 2>/dev/null | grep -q .; then
    sudo bash -c '
      if [[ ! -f /swapfile ]]; then
        fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
      fi
    ' 2>/dev/null || true
  fi

  echo "==> 安装 leetcode-cli（nvm，用户目录）..."
  dev_install_leetcode_cli "$dev_user"

  if [[ ! -d "$lc_dir/docs/.git" ]]; then
    echo "==> 克隆离线题面..."
    sudo -u "$dev_user" git clone --depth 1 https://github.com/doocs/leetcode.git "$lc_dir/docs"
  fi

  echo "LeetCode 环境 OK。详见 ~/projects/leetcode"
  if ! dev_leetcode_cmd "$dev_user" 'leetcode user 2>/dev/null' | grep -q "Username"; then
    echo "首次登录: leetcode user -c   # 粘贴 LEETCODE_SESSION cookie"
  fi
}

if [[ "${1:-}" == "--on-instance" ]]; then
  shift
  run_on_instance "${1:-dev}"
  exit 0
fi

# ---- 从本机推到 EC2 ----
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
SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
[[ -f "$KEY" ]] && SSH_OPTS+=(-i "$KEY")

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "未找到运行中的实例，请先 make up"
  exit 1
fi

echo "在 $USER@$IP 上配置 LeetCode 环境..."
scp "${SSH_OPTS[@]}" \
  "$ROOT/scripts/setup-leetcode.sh" \
  "$ROOT/scripts/lib/nvm-dev.sh" \
  "$USER@$IP:/tmp/"
ssh "${SSH_OPTS[@]}" "$USER@$IP" 'bash /tmp/setup-leetcode.sh --on-instance'

echo ""
echo "完成。Cursor 连接 aws-vibe-dev，打开 ~/projects/leetcode"
