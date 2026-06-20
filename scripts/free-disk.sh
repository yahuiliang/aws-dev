#!/usr/bin/env bash
# 远程实例根盘腾空间（apt 缓存、journal、Docker 等，不动 /data）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
# shellcheck source=lib/ssh_connect.sh
source "$ROOT/scripts/lib/ssh_connect.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"

cd "$TF_DIR"
IP=$(terraform output -raw public_ip 2>/dev/null | tr -d '[:space:]' || true)
USER=$(tfvar dev_username dev)
build_ssh_opts -o BatchMode=yes -o ConnectTimeout=15

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "未找到运行中的实例，请先 make up 或 make start"
  exit 1
fi

echo "→ 远程清理根盘 ($USER@$IP)..."
ssh "${SSH_OPTS[@]}" "$USER@$IP" 'bash -s' <<'REMOTE'
set -euo pipefail

show_disk() {
  echo "=== 磁盘使用 ==="
  df -h / /data 2>/dev/null || df -h /
  echo ""
}

show_disk

echo "→ 清理 apt 缓存..."
sudo apt-get clean
sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y

echo "→ 压缩 systemd journal..."
sudo journalctl --vacuum-size=100M

echo "→ 清理旧日志压缩包..."
sudo find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -delete 2>/dev/null || true

if command -v docker &>/dev/null; then
  echo "→ 清理 Docker 未使用镜像/容器..."
  sudo docker system prune -af 2>/dev/null || true
fi

if [[ -d /var/lib/snapd/cache ]]; then
  echo "→ 清理 snap 缓存..."
  sudo rm -rf /var/lib/snapd/cache/* 2>/dev/null || true
fi

echo ""
echo "=== 清理后 ==="
show_disk

used=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [[ "$used" -ge 90 ]]; then
  echo "⚠ 根盘仍紧张（已用 ${used}%），/ 下各目录占用："
  sudo du -xh / --max-depth=1 2>/dev/null | sort -h | tail -10
  echo ""
  echo "若仍不足，可考虑 make restart 重建实例（/data 数据盘保留）。"
fi
REMOTE

echo "完成。可再运行 make fix"
