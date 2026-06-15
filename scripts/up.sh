#!/usr/bin/env bash
# 一键部署 / 更新开发机
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

cd "$TF_DIR"

if [[ ! -f terraform.tfvars ]]; then
  echo "未找到 terraform.tfvars，正在从示例复制..."
  cp terraform.tfvars.example terraform.tfvars
fi

echo "→ 同步 SSH 白名单 IP..."
"$ROOT/scripts/set-my-ip.sh"

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"
ensure_dev_rdp_password

if [[ ! -f ~/.ssh/id_ed25519.pub ]]; then
  if [[ -f ~/.ssh/id_rsa.pub ]]; then
    echo "未找到 id_ed25519.pub，改用 ~/.ssh/id_rsa.pub"
    sed -i '' 's#^[[:space:]]*ssh_public_key_path.*#ssh_public_key_path = "~/.ssh/id_rsa.pub"#' terraform.tfvars
  else
    echo "未找到 SSH 公钥，正在生成 ed25519..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "aws-dev-box"
  fi
fi

terraform init -upgrade

# shellcheck source=lib/spot_apply.sh
source "$ROOT/scripts/lib/spot_apply.sh"
spot_apply_with_fallback "$TF_DIR" "$@"

echo ""
echo "→ 等待环境就绪..."
"$ROOT/scripts/wait-ready.sh"

echo ""
echo "========== 部署完成 =========="
terraform output -json | jq -r '"SSH: \(.ssh_command.value)"'
echo "Cursor:  运行 make cursor 配置 Remote SSH"
