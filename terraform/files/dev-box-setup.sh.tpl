#!/bin/bash
# 实例初始化（可重复执行，systemd 也会在开机时跑）
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

DEV_USER="${dev_username}"
INSTALL_DOCKER="${install_docker}"
SSH_PUBLIC_KEY='${ssh_public_key}'
AUTO_STOP_IDLE="${auto_stop_idle_minutes}"
AUTO_STOP_CHECK="${auto_stop_check_interval_minutes}"
AWS_REGION="${aws_region}"
AUTO_STOP_SCRIPT_B64='${auto_stop_script_b64}'

log() { echo "[dev-box-setup] $*"; logger -t dev-box-setup "$*"; }

find_data_device() {
  local d name size type mount
  # Nitro 实例上 /dev/xvdf 通常表现为 /dev/nvme1n1
  for d in /dev/nvme1n1 /dev/nvme2n1 /dev/xvdf /dev/sdf; do
    [[ -b "$d" ]] && [[ "$d" != /dev/nvme0n1 ]] && echo "$d" && return 0
  done
  while IFS= read -r name size type mount; do
    [[ "$type" == "disk" && -z "$mount" && "$name" != "nvme0n1" ]] && echo "/dev/$name" && return 0
  done < <(lsblk -ndo NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null)
  return 1
}

wait_for_data_device() {
  local i dev
  for i in $(seq 1 180); do
    if dev=$(find_data_device); then
      echo "$dev"
      return 0
    fi
    sleep 2
  done
  return 1
}

setup_dev_user() {
  if ! id "$DEV_USER" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo "$DEV_USER"
    echo "$DEV_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$DEV_USER"
  fi
  mkdir -p "/home/$DEV_USER/.ssh"
  chmod 700 "/home/$DEV_USER/.ssh"
  echo "$SSH_PUBLIC_KEY" > "/home/$DEV_USER/.ssh/authorized_keys"
  chmod 600 "/home/$DEV_USER/.ssh/authorized_keys"
  chown -R "$DEV_USER:$DEV_USER" "/home/$DEV_USER"
  setup_login_hint
}

setup_login_hint() {
  local rc="/home/$DEV_USER/.bashrc"
  mkdir -p "/home/$DEV_USER"
  touch "$rc"
  chown "$DEV_USER:$DEV_USER" "$rc"
  grep -q dev-box-init-hint "$rc" 2>/dev/null && return 0
  cat >> "$rc" <<'EOF'

# dev-box-init-hint
if [[ ! -f /data/.initialized ]]; then
  echo "[dev-box] 环境仍在安装（Node 等开发工具），约 5 分钟。进度: sudo journalctl -t dev-box-setup -f"
fi
EOF
  chown "$DEV_USER:$DEV_USER" "$rc"
}

mount_data_volume() {
  local dev="$1"
  log "Using data device $dev"

  if ! blkid "$dev" >/dev/null 2>&1; then
    log "Formatting $dev ..."
    mkfs.ext4 -F "$dev"
  fi

  mkdir -p /data
  if ! grep -q '/data' /etc/fstab; then
    echo "$dev /data ext4 defaults,nofail 0 2" >> /etc/fstab
  fi
  mount -a

  mkdir -p "/data/home/$DEV_USER"
  if [[ ! -L "/home/$DEV_USER" ]]; then
    if [[ -d "/home/$DEV_USER" && ! -L "/home/$DEV_USER" ]]; then
      # 数据盘已有 home 时勿用根盘覆盖（会冲掉 .bashrc 里的 nvm 等配置）
      if [[ -z "$(ls -A "/data/home/$DEV_USER" 2>/dev/null)" ]]; then
        rsync -a "/home/$DEV_USER/" "/data/home/$DEV_USER/" || true
      fi
      rm -rf "/home/$DEV_USER"
    fi
    ln -sfn "/data/home/$DEV_USER" "/home/$DEV_USER"
  fi
  chown -R "$DEV_USER:$DEV_USER" "/data/home/$DEV_USER"
  setup_login_hint
  # 确保密钥在持久化盘
  mkdir -p "/data/home/$DEV_USER/.ssh"
  echo "$SSH_PUBLIC_KEY" > "/data/home/$DEV_USER/.ssh/authorized_keys"
  chmod 700 "/data/home/$DEV_USER/.ssh"
  chmod 600 "/data/home/$DEV_USER/.ssh/authorized_keys"
  chown -R "$DEV_USER:$DEV_USER" "/data/home/$DEV_USER/.ssh"
}

setup_ssh_hardening() {
  mkdir -p /etc/ssh/sshd_config.d
  cat > /usr/local/bin/dev-box-ssh-gate <<'GATE'
#!/bin/bash
# 初始化完成前拒绝 dev 登录（ForceCommand 调用）
if [[ ! -f /data/.initialized ]]; then
  echo ""
  echo "  [dev-box] 开发环境仍在初始化（Node 等开发工具）"
  echo "  请 3–8 分钟后再连；本地可运行: make wait-ready"
  echo ""
  exit 1
fi
if [[ -n "$${SSH_ORIGINAL_COMMAND:-}" ]]; then
  exec /bin/bash -c "$${SSH_ORIGINAL_COMMAND}"
else
  exec /bin/bash -l
fi
GATE
  chmod +x /usr/local/bin/dev-box-ssh-gate

  cat > /etc/ssh/sshd_config.d/99-dev-box.conf <<EOF
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers ${dev_username}
EOF
  if [[ "${block_ssh_until_ready}" == "true" ]]; then
    cat >> /etc/ssh/sshd_config.d/99-dev-box.conf <<EOF

Match User ${dev_username}
    ForceCommand /usr/local/bin/dev-box-ssh-gate
EOF
  fi
  systemctl reload ssh || systemctl reload sshd
  if id ubuntu &>/dev/null; then
    usermod -L ubuntu
    passwd -l ubuntu 2>/dev/null || true
  fi
}

setup_packages() {
  apt-get update -y
  apt-get install -y \
    build-essential git curl wget unzip jq htop tmux zsh \
    python3 python3-pip python3-venv ripgrep fd-find \
    cmake clang clangd gdb clang-format ninja-build pkg-config

  setup_git
  setup_cpp_toolchain
  ensure_dev_nvm

  if [[ "$INSTALL_DOCKER" == "true" ]] && ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$DEV_USER"
  fi
}

setup_git() {
  log "Configuring git for $DEV_USER"
  sudo -u "$DEV_USER" git config --global init.defaultBranch main
  sudo -u "$DEV_USER" git config --global color.ui auto
  sudo -u "$DEV_USER" git config --global core.editor "vim"
  sudo -u "$DEV_USER" git config --global pull.rebase false
  if ! sudo -u "$DEV_USER" git config --global user.name &>/dev/null; then
    sudo -u "$DEV_USER" git config --global user.name "$DEV_USER"
    sudo -u "$DEV_USER" git config --global user.email "$DEV_USER@ec2-remote"
    log "Git identity not set; using placeholder (run: git config --global user.email 'you@example.com')"
  fi
}

setup_cpp_toolchain() {
  log "Verifying C++ toolchain"
  sudo -u "$DEV_USER" mkdir -p "/data/home/$DEV_USER/projects"
  if ! sudo -u "$DEV_USER" g++ --version &>/dev/null; then
    log "ERROR: g++ not available after build-essential install"
    return 1
  fi
  log "C++: $(g++ --version | head -1) | cmake $(cmake --version | head -1 | awk '{print $3}') | clang $(clang --version | head -1 | awk '{print $3}') | clangd $(clangd --version | head -1 | awk '{print $3}')"
}

ensure_dev_nvm() {
  # t4g.micro 装 Node 需要 swap
  if ! swapon --show 2>/dev/null | grep -q .; then
    if [[ ! -f /swapfile ]]; then
      log "Adding 1GB swap for Node install..."
      fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
    fi
  fi

  sudo -u "$DEV_USER" bash -lc '
    set -euo pipefail
    export NVM_DIR="$HOME/.nvm"
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    . "$NVM_DIR/nvm.sh"
    nvm install 20
    nvm alias default 20
    nvm use default
    npm config delete prefix 2>/dev/null || true
    export PATH="$(dirname "$(nvm which current)"):$PATH"
    # 写入 .profile：login shell 会加载；.bashrc 在非交互模式下会提前 return
    touch "$HOME/.profile"
    grep -q NVM_DIR "$HOME/.profile" 2>/dev/null || cat >> "$HOME/.profile" <<'"'"'EOF'"'"'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
export NODE_OPTIONS="--no-warnings"
EOF
  '
}

setup_autostop() {
  [[ "$${AUTO_STOP_IDLE:-0}" -le 0 ]] && return 0
  apt-get install -y awscli
  mkdir -p /var/lib/dev-box
  echo "$AUTO_STOP_SCRIPT_B64" | base64 -d > /usr/local/bin/auto-stop.sh
  chmod +x /usr/local/bin/auto-stop.sh
  cat > /etc/default/auto-stop <<EOF
IDLE_THRESHOLD_MINUTES=${auto_stop_idle_minutes}
CHECK_INTERVAL_MINUTES=${auto_stop_check_interval_minutes}
AWS_REGION=${aws_region}
EOF
  cat > /etc/systemd/system/auto-stop.service <<'EOF'
[Unit]
Description=Check idle and stop EC2 instance
After=network-online.target
[Service]
Type=oneshot
EnvironmentFile=/etc/default/auto-stop
ExecStart=/usr/local/bin/auto-stop.sh
EOF
  cat > /etc/systemd/system/auto-stop.timer <<EOF
[Unit]
Description=Run auto-stop idle check
[Timer]
OnBootSec=5min
OnUnitActiveSec=${auto_stop_check_interval_minutes}min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now auto-stop.timer
  cat > /usr/local/bin/keepalive <<EOF
#!/bin/bash
touch /var/lib/dev-box/keepalive
EOF
  chmod +x /usr/local/bin/keepalive
}

# ---- main ----
log "Starting dev-box setup"
setup_dev_user
setup_ssh_hardening

if dev=$(wait_for_data_device); then
  mount_data_volume "$dev"
  setup_packages
  setup_autostop
  date -Is > /data/.initialized
  log "Setup complete"
else
  log "WARN: data volume not found yet; SSH ready, run: sudo /usr/local/bin/dev-box-setup.sh"
fi
