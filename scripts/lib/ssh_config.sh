#!/usr/bin/env bash
# 生成 Cursor / VS Code Remote SSH 配置块（可单测）

write_vscode_ssh_block() {
  local ssh_config="$1" ip="$2" user="$3" identity_file="$4"
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
$end_marker
EOF
}
