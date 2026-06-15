#!/usr/bin/env bash
# 生成 Cursor / VS Code Remote SSH 配置块（可单测）

write_vscode_ssh_block() {
  local ssh_config="$1" ip="$2" user="$3" identity_file="$4" rdp_forward="${5:-false}"
  local host="aws-vibe-dev"
  local marker="# aws-vibe-dev managed block"
  local end_marker="# end aws-vibe-dev"

  touch "$ssh_config"

  if grep -q "$marker" "$ssh_config"; then
    awk -v start="$marker" -v end="$end_marker" '
      $0 ~ start { skip=1; next }
      $0 ~ end { skip=0; next }
      !skip { print }
    ' "$ssh_config" > "${ssh_config}.tmp"
    mv "${ssh_config}.tmp" "$ssh_config"
  fi

  cat >> "$ssh_config" <<EOF

$marker
Host $host
  HostName $ip
  User $user
  IdentityFile $identity_file
  StrictHostKeyChecking accept-new
EOF
  if [[ "$rdp_forward" == "true" ]]; then
    cat >> "$ssh_config" <<EOF
  LocalForward 3389 127.0.0.1:3389
EOF
  fi
  cat >> "$ssh_config" <<EOF
$end_marker
EOF
}
