#!/usr/bin/env bash
# 远端 dev-box 就绪检测（与 tfvars 开关一致，供 wait-ready.sh 使用）
# 用法: TFVARS_FILE=... source scripts/lib/ready_check.sh

remote_setup_ready_script() {
  local install_desktop install_docker
  install_desktop=$(tfvar install_desktop true)
  install_docker=$(tfvar install_docker false)

  cat <<'EOF'
set -e
# setup 仍在跑时不算就绪
if pgrep -f '/usr/local/bin/dev-box-setup.sh' >/dev/null 2>&1; then
  exit 1
fi
# 实例本地标记（重建实例后会消失，避免数据盘旧 .initialized 误判）
test -f /var/lib/dev-box/setup-complete || exit 1
EOF

  if [[ "$install_desktop" == "true" ]]; then
    cat <<'EOF'
systemctl is-active --quiet xrdp || exit 1
test -x /opt/firefox/firefox || exit 1
EOF
  fi

  if [[ "$install_docker" == "true" ]]; then
    cat <<'EOF'
command -v docker >/dev/null || exit 1
EOF
  fi

  echo "exit 0"
}
