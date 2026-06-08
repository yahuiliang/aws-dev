#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "[user-data] $*"; }

# 写入可重复执行的 setup 脚本 + systemd（数据盘晚于实例挂载时自动重试）
cat > /usr/local/bin/dev-box-setup.sh <<'SETUPEOF'
${setup_script}
SETUPEOF
chmod +x /usr/local/bin/dev-box-setup.sh

cat > /etc/systemd/system/dev-box-setup.service <<'EOF'
[Unit]
Description=Dev box bootstrap (mount data volume, install tools)
After=cloud-init.service network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/dev-box-setup.sh

[Install]
WantedBy=multi-user.target
EOF

# 数据盘晚挂载时：每 2 分钟重试，直到 /data/.initialized 出现
cat > /etc/systemd/system/dev-box-setup-retry.service <<'EOF'
[Unit]
Description=Retry dev-box setup until complete

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'test -f /data/.initialized || /usr/local/bin/dev-box-setup.sh'
EOF

cat > /etc/systemd/system/dev-box-setup-retry.timer <<'EOF'
[Unit]
Description=Retry dev-box setup timer

[Timer]
OnBootSec=90s
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable dev-box-setup.service
systemctl enable dev-box-setup-retry.timer

log "Running dev-box-setup (first boot)..."
/usr/local/bin/dev-box-setup.sh || true

# 数据盘挂载可能晚于 user-data，多等几次
for delay in 30 60 120; do
  sleep "$delay"
  if [[ -f /data/.initialized ]]; then
    log "Setup complete (marker found)"
    break
  fi
  log "Retry dev-box-setup after $${delay}s..."
  /usr/local/bin/dev-box-setup.sh || true
done

systemctl start dev-box-setup-retry.timer || true
log "user-data finished (leetcode 等 user-data 完成后约 3–8 分钟可用)"
