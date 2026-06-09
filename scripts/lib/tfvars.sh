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

# 更新 allowed_ssh_cidr（set-my-ip.sh 核心逻辑，可单测）
update_allowed_ssh_cidr() {
  local tfvars_file="$1" new_cidr="$2"
  sed -i '' "s#^\([[:space:]]*allowed_ssh_cidr[[:space:]]*=[[:space:]]*\)\"[^\"]*\"#\1\"${new_cidr}\"#" "$tfvars_file"
}
