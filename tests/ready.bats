#!/usr/bin/env bats
# 远端就绪检测脚本

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/lib/tfvars.sh"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/lib/ready_check.sh"
  TFVARS=$(mktemp)
  cp "$BATS_TEST_DIRNAME/fixtures/sample.tfvars" "$TFVARS"
  TFVARS_FILE="$TFVARS"
}

teardown() {
  rm -f "$TFVARS"
}

@test "remote_setup_ready_script 包含 setup-complete 与进程检测" {
  script=$(remote_setup_ready_script)
  [[ "$script" == *"/var/lib/dev-box/setup-complete"* ]]
  [[ "$script" == *"dev-box-setup.sh"* ]]
}

@test "remote_setup_ready_script install_desktop 时检查 xrdp 与 firefox" {
  cat >> "$TFVARS" <<'EOF'
install_desktop = true
EOF
  script=$(remote_setup_ready_script)
  [[ "$script" == *"xrdp"* ]]
  [[ "$script" == *"/opt/firefox/firefox"* ]]
}
