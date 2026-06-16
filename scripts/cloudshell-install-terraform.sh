#!/usr/bin/env bash
# 在 AWS CloudShell 中安装 Terraform（持久化到 ~/bin，跨 session 保留）
#
# CloudShell 入口：控制台顶部工具栏的终端图标（Region 需与 terraform.tfvars 一致）
#
# 用法:
#   git clone <本仓库> && cd ec2远程
#   ./scripts/cloudshell-install-terraform.sh
#
# 或指定版本:
#   TF_VERSION=1.9.8 ./scripts/cloudshell-install-terraform.sh
#
# 环境变量:
#   TF_VERSION   默认 1.5.7（与 .github/workflows/test.yml 一致，满足 required_version >= 1.5）
#   INSTALL_DIR  默认 ~/bin（CloudShell 会自动把 ~/bin 加入 PATH）
set -euo pipefail

TF_VERSION="${TF_VERSION:-1.5.7}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/bin}"

terraform_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *)
      echo "不支持的 CPU 架构: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

terraform_zip_name() {
  echo "terraform_${TF_VERSION}_linux_$(terraform_arch).zip"
}

terraform_download_url() {
  echo "https://releases.hashicorp.com/terraform/${TF_VERSION}/$(terraform_zip_name)"
}

installed_version() {
  command -v terraform &>/dev/null || return 1
  if command -v jq &>/dev/null; then
    terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null && return 0
  fi
  terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

ensure_install_dir() {
  mkdir -p "$INSTALL_DIR"
}

ensure_path() {
  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) return 0 ;;
  esac

  if [[ -f "$HOME/.bashrc" ]] && ! grep -qF "$INSTALL_DIR" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# terraform (cloudshell-install-terraform.sh)\nexport PATH="%s:$PATH"\n' "$INSTALL_DIR" >>"$HOME/.bashrc"
    echo "→ 已将 $INSTALL_DIR 写入 ~/.bashrc"
  fi

  export PATH="${INSTALL_DIR}:$PATH"
}

download_terraform() {
  local tmpdir zip_name url
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN
  zip_name=$(terraform_zip_name)
  url=$(terraform_download_url)

  echo "→ 下载 Terraform ${TF_VERSION} ..."
  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$tmpdir/$zip_name"
  elif command -v wget &>/dev/null; then
    wget -q "$url" -O "$tmpdir/$zip_name"
  else
    echo "需要 curl 或 wget" >&2
    exit 1
  fi

  if ! command -v unzip &>/dev/null; then
    echo "需要 unzip（CloudShell 通常已预装）" >&2
    exit 1
  fi

  unzip -qo "$tmpdir/$zip_name" -d "$tmpdir"
  install -m 0755 "$tmpdir/terraform" "$INSTALL_DIR/terraform"
  echo "→ 已安装到 $INSTALL_DIR/terraform"
}

verify_install() {
  local ver
  ver=$(installed_version || true)
  if [[ "$ver" != "$TF_VERSION" ]]; then
    echo "安装校验失败: 期望 $TF_VERSION，实际 ${ver:-未知}" >&2
    exit 1
  fi
  echo "✓ terraform $ver"
  terraform -help >/dev/null
  echo "✓ terraform 可执行"
}

print_next_steps() {
  cat <<EOF

========== 下一步（在 CloudShell 部署本仓库）==========

1. 准备代码与配置（若尚未 clone）:
   git clone <你的仓库地址> && cd ec2远程
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars

2. 同步本地 state（若之前在 Mac 上部署过）:
   CloudShell 菜单 Actions → Upload file，上传本地的:
     - terraform/terraform.tfstate
     - terraform/.terraform.lock.hcl（可选，init 会再拉）
   否则 CloudShell 会当成全新部署。

3. 配置 SSH 公钥与白名单 IP:
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "aws-dev-box"   # 若无密钥
   MY_IP=\$(curl -4 -fsS ifconfig.me)
   # 手动编辑 terraform/terraform.tfvars:
   #   allowed_ssh_cidr = "\${MY_IP}/32"
   #   ssh_public_key_path = "~/.ssh/id_ed25519.pub"

4. 在 terraform/ 目录执行:
   cd terraform
   terraform init -upgrade
   terraform plan
   terraform apply

说明:
- CloudShell 已自动带上 Console 登录身份的 AWS 权限，一般无需配置 Access Key。
- make up / wait-ready 依赖 SSH 连实例，适合本地 Mac；CloudShell 只做 terraform apply 即可。
- 每个 AWS Region 的 CloudShell 环境独立；请在 terraform.tfvars 的 aws_region 对应 Region 里操作。
- 换网络后记得更新 allowed_ssh_cidr，否则 SSH 会连不上。

EOF
}

main() {
  if [[ -n "${AWS_EXECUTION_ENV:-}" ]] || [[ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]]; then
    echo "→ 检测到 AWS 托管环境（CloudShell / ECS 等）"
  else
    echo "→ 提示: 未检测到 CloudShell 环境变量，脚本仍可在 Linux 上安装 Terraform"
  fi

  ensure_install_dir
  ensure_path

  current=$(installed_version || true)
  if [[ "$current" == "$TF_VERSION" ]]; then
    echo "✓ terraform $TF_VERSION 已安装，跳过"
  else
    [[ -n "$current" ]] && echo "→ 当前版本: $current，将安装 $TF_VERSION"
    download_terraform
    verify_install
  fi

  if command -v aws &>/dev/null && aws sts get-caller-identity &>/dev/null; then
    echo "✓ AWS 已登录: $(aws sts get-caller-identity --query Account --output text)"
  else
    echo "⚠ 未检测到 AWS CLI 凭证（CloudShell 中通常会自动配置）"
  fi

  if command -v jq &>/dev/null; then
    echo "✓ jq ($(jq --version 2>&1 | head -1))"
  else
    echo "⚠ 未找到 jq，terraform output 解析可能不便（CloudShell 一般已预装）"
  fi

  print_next_steps
}

main "$@"
