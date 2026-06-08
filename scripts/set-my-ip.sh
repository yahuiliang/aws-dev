#!/usr/bin/env bash
# 自动获取本机公网 IP 并写入 terraform/terraform.tfvars
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TFVARS="$ROOT/terraform/terraform.tfvars"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
DRY_RUN=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

自动查公网 IP，写入 terraform.tfvars 的 allowed_ssh_cidr。

选项:
  -n, --dry-run   只显示 IP，不修改文件
  -h, --help      显示帮助

示例:
  ./scripts/set-my-ip.sh
  make set-ip
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知选项: $1"; usage; exit 1 ;;
  esac
done

fetch_public_ip() {
  local ip url
  for url in \
    "https://ifconfig.me" \
    "https://icanhazip.com" \
    "https://api.ipify.org"; do
    ip=$(curl -4 -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || continue
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

if [[ ! -f "$TFVARS" ]]; then
  echo "未找到 $TFVARS，先运行: make init"
  exit 1
fi

echo "正在查询公网 IP..."
if ! PUBLIC_IP=$(fetch_public_ip); then
  echo "获取公网 IP 失败，请检查网络后重试"
  exit 1
fi

NEW_CIDR="${PUBLIC_IP}/32"
CURRENT=$(grep 'allowed_ssh_cidr' "$TFVARS" | head -1 | sed -n 's/.*=[[:space:]]*"\([^"]*\)".*/\1/p' || true)

echo "公网 IP:  $PUBLIC_IP"
echo "新规则:   allowed_ssh_cidr = \"$NEW_CIDR\""

if [[ -n "$CURRENT" ]]; then
  echo "当前配置: allowed_ssh_cidr = \"$CURRENT\""
  if [[ "$CURRENT" == "$NEW_CIDR" ]]; then
    echo "无需更新，已是最新 IP。"
    exit 0
  fi
fi

if [[ "$DRY_RUN" == 1 ]]; then
  echo "（dry-run，未修改文件）"
  exit 0
fi

# 用 # 作 sed 分隔符，避免 CIDR 里的 /32 被误解析
TFVARS_FILE="$TFVARS"
update_allowed_ssh_cidr "$TFVARS" "$NEW_CIDR"

echo "已更新 $TFVARS"
echo "换网络后连不上时，重新运行: make set-ip && make up"
