#!/usr/bin/env bats
# SSH 配置块生成

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/lib/ssh_config.sh"
  SSH_CONFIG=$(mktemp)
}

teardown() {
  rm -f "$SSH_CONFIG" "${SSH_CONFIG}.tmp"
}

@test "write_vscode_ssh_block 写入 Host 与 User" {
  write_vscode_ssh_block "$SSH_CONFIG" "203.0.113.10" "dev" "/Users/me/.ssh/id_rsa"
  grep -q 'Host aws-vibe-dev' "$SSH_CONFIG"
  grep -q 'HostName 203.0.113.10' "$SSH_CONFIG"
  grep -q 'User dev' "$SSH_CONFIG"
  grep -q 'IdentityFile /Users/me/.ssh/id_rsa' "$SSH_CONFIG"
}

@test "write_vscode_ssh_block 重复执行会替换旧块" {
  write_vscode_ssh_block "$SSH_CONFIG" "203.0.113.10" "dev" "/Users/me/.ssh/id_rsa"
  write_vscode_ssh_block "$SSH_CONFIG" "203.0.113.20" "dev" "/Users/me/.ssh/id_rsa"
  [ "$(grep -c 'Host aws-vibe-dev' "$SSH_CONFIG")" -eq 1 ]
  grep -q 'HostName 203.0.113.20' "$SSH_CONFIG"
  ! grep -q '203.0.113.10' "$SSH_CONFIG"
}

@test "write_vscode_ssh_block 保留块外内容" {
  echo "# my other host" > "$SSH_CONFIG"
  write_vscode_ssh_block "$SSH_CONFIG" "203.0.113.10" "dev" "/Users/me/.ssh/id_rsa"
  grep -q '# my other host' "$SSH_CONFIG"
}

@test "write_vscode_ssh_block install_desktop 时写入 LocalForward" {
  write_vscode_ssh_block "$SSH_CONFIG" "203.0.113.10" "dev" "/Users/me/.ssh/id_rsa" true
  grep -q 'LocalForward 3389 127.0.0.1:3389' "$SSH_CONFIG"
}

@test "write_vscode_ssh_block 未开 desktop 时不写 LocalForward" {
  write_vscode_ssh_block "$SSH_CONFIG" "203.0.113.10" "dev" "/Users/me/.ssh/id_rsa" false
  ! grep -q 'LocalForward' "$SSH_CONFIG"
}
