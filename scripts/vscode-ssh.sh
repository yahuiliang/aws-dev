#!/usr/bin/env bash
# 写入 ~/.ssh/config，供 Cursor / VS Code Remote SSH 使用
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"

cd "$TF_DIR"

IP=$(terraform output -raw public_ip 2>/dev/null || true)

# shellcheck source=lib/tfvars.sh
source "$ROOT/scripts/lib/tfvars.sh"
# shellcheck source=lib/ssh_config.sh
source "$ROOT/scripts/lib/ssh_config.sh"
# shellcheck source=lib/ssh_connect.sh
source "$ROOT/scripts/lib/ssh_connect.sh"
TFVARS_FILE="$TF_DIR/terraform.tfvars"

USER=$(tfvar dev_username dev)
IDENTITY_FILE=$(ssh_identity_from_tfvars)

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "未找到实例 IP"
  exit 1
fi

SSH_CONFIG="$HOME/.ssh/config"
INSTALL_DESKTOP=$(tfvar install_desktop true)
write_vscode_ssh_block "$SSH_CONFIG" "$IP" "$USER" "$IDENTITY_FILE" "$INSTALL_DESKTOP"

echo "已写入 ~/.ssh/config -> Host aws-vibe-dev ($IP)"
echo "  User=$USER  IdentityFile=$IDENTITY_FILE"
echo "Cursor: Remote-SSH 连接 aws-vibe-dev"
if [[ "$INSTALL_DESKTOP" == "true" ]]; then
  echo "远程桌面: ssh -N aws-vibe-dev 后 Windows App 连 127.0.0.1:3389 (user=$USER)"
fi
