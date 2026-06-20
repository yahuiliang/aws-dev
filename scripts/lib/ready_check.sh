#!/usr/bin/env bash
# 远端 dev-box 就绪检测（block_ssh_until_ready=false 时使用）
# 用法: TFVARS_FILE=... source scripts/lib/ready_check.sh

remote_setup_ready_script() {
  cat <<'EOF'
set -e
if pgrep -f '/usr/local/bin/dev-box-setup.sh' >/dev/null 2>&1; then
  exit 1
fi
test -f /var/lib/dev-box/setup-complete
EOF
}
