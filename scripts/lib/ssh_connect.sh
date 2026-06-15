#!/usr/bin/env bash
# 从 tfvars 解析 SSH 身份与连接选项（需先 source tfvars.sh 并设置 TFVARS_FILE）

DEFAULT_SSH_PUB_KEY="${DEFAULT_SSH_PUB_KEY:-~/.ssh/id_ed25519.pub}"
SSH_OPTS=()

ssh_identity_from_tfvars() {
  local pub_path identity
  pub_path=$(tfvar ssh_public_key_path "$DEFAULT_SSH_PUB_KEY")
  pub_path="${pub_path/#\~/$HOME}"
  identity="${pub_path%.pub}"
  if [[ ! -f "$identity" && -f "$HOME/.ssh/id_rsa" ]]; then
    identity="$HOME/.ssh/id_rsa"
  fi
  echo "$identity"
}

# 用法: build_ssh_opts [-o ConnectTimeout=10 ...]
build_ssh_opts() {
  local identity
  identity=$(ssh_identity_from_tfvars)
  SSH_OPTS=(-o StrictHostKeyChecking=accept-new "$@")
  [[ -f "$identity" ]] && SSH_OPTS=(-i "$identity" "${SSH_OPTS[@]}")
}
