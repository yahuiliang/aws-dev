#!/usr/bin/env bash
# 从 terraform.tfvars 读取变量（供脚本与单元测试复用）
# 用法: TFVARS_FILE=/path/to/terraform.tfvars source scripts/lib/tfvars.sh

tfvar() {
  local key="$1" default="${2:-}"
  local file="${TFVARS_FILE:?TFVARS_FILE 未设置}"
  local val

  val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | head -1 \
    | sed -n 's/^[[:space:]]*[^=]*=[[:space:]]*"\([^"]*\)".*/\1/p') || true
  if [[ -z "$val" ]]; then
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | head -1 \
      | sed -En 's/^[[:space:]]*[^=]*=[[:space:]]*([0-9]+).*/\1/p') || true
  fi
  if [[ -z "$val" ]]; then
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | head -1 \
      | sed -En 's/^[[:space:]]*[^=]*=[[:space:]]*(true|false).*/\1/p') || true
  fi
  echo "${val:-$default}"
}

# 读取 HCL 字符串列表，如 instance_type_fallbacks = ["t4g.micro", "t4g.medium"]
tfvar_list() {
  local key="$1"
  local file="${TFVARS_FILE:?TFVARS_FILE 未设置}"
  local line item

  line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | head -1) || true
  [[ -n "$line" ]] || return 0

  if echo "$line" | grep -qE '\[[[:space:]]*\]'; then
    return 0
  fi

  while IFS= read -r item; do
    item=${item//\"/}
    [[ -n "$item" ]] && echo "$item"
  done < <(echo "$line" | grep -oE '"[^"]+"')
}

# 更新 allowed_ssh_cidr（set-my-ip.sh 核心逻辑，可单测）
update_allowed_ssh_cidr() {
  local tfvars_file="$1" new_cidr="$2"
  sed -i '' "s#^\([[:space:]]*allowed_ssh_cidr[[:space:]]*=[[:space:]]*\)\"[^\"]*\"#\1\"${new_cidr}\"#" "$tfvars_file"
}

# 写入 dev_rdp_password（HCL 双引号字符串转义）
update_dev_rdp_password() {
  local tfvars_file="$1" password="$2"
  TFVARS_PW="$password" awk '
    /^[[:space:]]*#?[[:space:]]*dev_rdp_password[[:space:]]*=/ { next }
    { print }
    END {
      pw = ENVIRON["TFVARS_PW"]
      gsub(/\\/, "\\\\", pw)
      gsub(/"/, "\\\"", pw)
      print "dev_rdp_password    = \"" pw "\""
    }
  ' "$tfvars_file" > "${tfvars_file}.tmp"
  mv "${tfvars_file}.tmp" "$tfvars_file"
}

# install_desktop 且未配置密码时交互询问（非 TTY 则跳过）
ensure_dev_rdp_password() {
  local file="${TFVARS_FILE:?TFVARS_FILE 未设置}"
  local install_desktop existing pw1 pw2

  install_desktop=$(tfvar install_desktop true)
  [[ "$install_desktop" == "true" ]] || return 0

  existing=$(tfvar dev_rdp_password "")
  if [[ -n "$existing" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "→ 提示: 远程桌面已开启，请 SSH 后运行 sudo passwd dev，或在 terraform.tfvars 设置 dev_rdp_password"
    return 0
  fi

  echo ""
  echo "→ 远程桌面需要 dev 用户密码（Windows App 登录用，与 SSH 密钥无关）"
  while true; do
    read -r -s -p "  RDP 密码 (至少 8 位，留空跳过): " pw1
    echo
    [[ -z "$pw1" ]] && return 0
    [[ ${#pw1} -ge 8 ]] || { echo "  密码至少 8 位"; continue; }
    read -r -s -p "  确认密码: " pw2
    echo
    [[ "$pw1" == "$pw2" ]] || { echo "  两次不一致，请重试"; continue; }
    break
  done

  update_dev_rdp_password "$file" "$pw1"
  echo "  已写入 terraform.tfvars"
}
