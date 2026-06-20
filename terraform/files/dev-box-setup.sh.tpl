#!/bin/bash
# 实例初始化（可重复执行，systemd 也会在开机时跑）
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

DEV_USER="${dev_username}"
INSTALL_DOCKER="${install_docker}"
INSTALL_DESKTOP="${install_desktop}"
INSTALL_CURSOR="${install_cursor}"
DESKTOP_RDP_PUBLIC="${desktop_rdp_public}"
DEV_RDP_PASSWORD_B64='${dev_rdp_password_b64}'
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
if [[ ! -f /var/lib/dev-box/setup-complete ]]; then
  echo "[dev-box] 环境仍在安装（Node/桌面等），约 5–15 分钟。进度: sudo journalctl -t dev-box-setup -f"
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
if [[ ! -f /var/lib/dev-box/setup-complete ]]; then
  echo ""
  echo "  [dev-box] 开发环境仍在初始化（工具链/远程桌面等）"
  echo "  请 5–15 分钟后再连；本地可运行: make wait-ready"
  echo "  进度: sudo journalctl -t dev-box-setup -f"
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
  reconcile_cursor_apt_repo
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

  setup_desktop
  ensure_cursor
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

write_firefox_desktop_entry() {
  cat > /usr/share/applications/firefox-devbox.desktop <<'FDEEOF'
[Desktop Entry]
Version=1.0
Name=Firefox
Comment=Web Browser
Exec=/opt/firefox/firefox %u
Icon=/opt/firefox/browser/chrome/icons/default/default128.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupWMClass=firefox
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/about;
FDEEOF
  update-desktop-database 2>/dev/null || true
}

configure_default_browser() {
  [[ "$INSTALL_DESKTOP" == "true" ]] || return 0
  [[ -x /opt/firefox/firefox ]] || return 0

  local home="/data/home/$DEV_USER"

  cat > /usr/local/bin/firefox-www-browser <<'FWEOF'
#!/bin/sh
exec /opt/firefox/firefox "$@"
FWEOF
  chmod +x /usr/local/bin/firefox-www-browser
  update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/firefox-www-browser 100 2>/dev/null || true
  update-alternatives --set x-www-browser /usr/local/bin/firefox-www-browser 2>/dev/null || true
  update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/local/bin/firefox-www-browser 100 2>/dev/null || true
  update-alternatives --set gnome-www-browser /usr/local/bin/firefox-www-browser 2>/dev/null || true

  mkdir -p "$home/.config/xfce4"
  cat > "$home/.config/xfce4/helpers.rc" <<'HREOF'
WebBrowser=firefox-devbox
HREOF

  if command -v xdg-mime &>/dev/null; then
    sudo -u "$DEV_USER" env HOME="$home" USER="$DEV_USER" \
      xdg-mime default firefox-devbox.desktop x-scheme-handler/http
    sudo -u "$DEV_USER" env HOME="$home" USER="$DEV_USER" \
      xdg-mime default firefox-devbox.desktop x-scheme-handler/https
    sudo -u "$DEV_USER" env HOME="$home" USER="$DEV_USER" \
      xdg-mime default firefox-devbox.desktop text/html
    sudo -u "$DEV_USER" env HOME="$home" USER="$DEV_USER" \
      xdg-mime default firefox-devbox.desktop application/xhtml+xml
  fi

  chown -R "$DEV_USER:$DEV_USER" "$home/.config"
  log "Default browser: firefox-devbox (/opt/firefox/firefox)"
}

ensure_desktop_browser() {
  [[ "$INSTALL_DESKTOP" == "true" ]] || return 0

  if [[ -x /opt/firefox/firefox ]] && /opt/firefox/firefox --version &>/dev/null; then
    log "Browser: $(/opt/firefox/firefox --version 2>/dev/null | head -1)"
    write_firefox_desktop_entry
    configure_default_browser
    return 0
  fi

  # apt 的 firefox 是 snap 包装；home 软链到 /data 时 snap 会报 8461: Not a directory
  log "Installing Firefox (Mozilla arm64 tarball; 避开 snap + symlink home 问题)..."
  apt-get install -y --no-install-recommends \
    libdbus-glib-1-2 libgtk-3-0 libasound2 libxt6 xdg-utils

  snap remove firefox 2>/dev/null || true
  apt-get remove -y firefox 2>/dev/null || true

  local tgz="/tmp/firefox.tar.xz"
  curl -fsSL -o "$tgz" "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64-aarch64&lang=en-US"
  rm -rf /opt/firefox
  tar -xJf "$tgz" -C /opt/
  rm -f "$tgz"

  ln -sf /opt/firefox/firefox /usr/local/bin/firefox
  write_firefox_desktop_entry

  if [[ -x /opt/firefox/firefox ]]; then
    configure_default_browser
    log "Browser ready: firefox -> /opt/firefox/firefox"
    return 0
  fi

  log "ERROR: failed to install Firefox"
  return 1
}

reconcile_cursor_apt_repo() {
  local has_repo=false
  grep -rq 'downloads.cursor.com/aptrepo' /etc/apt/sources.list.d/ 2>/dev/null && has_repo=true
  [[ "$INSTALL_CURSOR" == "true" || "$has_repo" == "true" ]] || return 0

  log "Reconciling Cursor apt repo (dedupe Signed-By)..."
  rm -f /etc/apt/sources.list.d/cursor.list /etc/apt/sources.list.d/cursor.sources /etc/apt/keyrings/cursor.gpg

  local arch keyring=/usr/share/keyrings/anysphere.gpg
  arch=$(dpkg --print-architecture)
  mkdir -p /usr/share/keyrings
  curl -fsSL https://downloads.cursor.com/keys/anysphere.asc | gpg --dearmor > "$keyring"
  chmod 644 "$keyring"

  cat > /etc/apt/sources.list.d/cursor.sources <<EOF
Types: deb
URIs: https://downloads.cursor.com/aptrepo
Suites: stable
Components: main
Architectures: $arch
Signed-By: $keyring
EOF
}

ensure_os_secret_storage_packages() {
  [[ "$INSTALL_CURSOR" == "true" || "$INSTALL_DESKTOP" == "true" ]] || return 0
  dpkg -s gnome-keyring &>/dev/null && dpkg -s libsecret-1-0 &>/dev/null && return 0

  log "Installing gnome-keyring for desktop secret storage..."
  apt-get install -y --no-install-recommends gnome-keyring libsecret-1-0
}

configure_cursor_secret_storage() {
  [[ "$INSTALL_CURSOR" == "true" ]] || return 0

  local home="/data/home/$DEV_USER"
  local argv="$home/.config/Cursor/argv.json"
  mkdir -p "$(dirname "$argv")"
  python3 - "$argv" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
data["password-store"] = "basic"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  chown -R "$DEV_USER:$DEV_USER" "$home/.config/Cursor"

  local de
  for de in /usr/share/applications/cursor*.desktop; do
    [[ -f "$de" ]] || continue
    grep -q 'no-sandbox' "$de" || sed -i 's|\(Exec=.*cursor[^ ]*\)|\1 --no-sandbox|' "$de"
    grep -q 'password-store=basic' "$de" || sed -i 's|\(Exec=.*cursor[^ ]*\)|\1 --password-store=basic|' "$de"
  done
  update-desktop-database 2>/dev/null || true
}

ensure_cursor() {
  [[ "$INSTALL_CURSOR" == "true" ]] || return 0

  reconcile_cursor_apt_repo
  ensure_os_secret_storage_packages

  if command -v cursor &>/dev/null && cursor --version &>/dev/null; then
    log "Cursor: $(cursor --version 2>/dev/null | head -1) ($(cursor --version 2>/dev/null | tail -1))"
  else
    log "Installing Cursor (official apt, arm64)..."
    apt-get update -y
    apt-get install -y --no-install-recommends cursor
  fi

  configure_cursor_secret_storage

  if command -v cursor &>/dev/null; then
    log "Cursor ready: $(cursor --version 2>/dev/null | head -1) (password-store=basic)"
    return 0
  fi

  log "ERROR: failed to install Cursor"
  return 1
}

ensure_xfce_icons() {
  [[ "$INSTALL_DESKTOP" == "true" ]] || return 0
  local marker="/var/lib/dev-box/xfce-icons-ready"

  if [[ -f "$marker" ]] && dpkg -s papirus-icon-theme &>/dev/null; then
    return 0
  fi

  log "Installing XFCE icon themes and file manager libs..."
  apt-get install -y --no-install-recommends \
    papirus-icon-theme adwaita-icon-theme gnome-icon-theme hicolor-icon-theme \
    shared-mime-info desktop-file-utils file \
    gvfs gvfs-backends gvfs-fuse \
    tumbler tumbler-plugins-extra ffmpegthumbnailer \
    libglib2.0-bin exo-utils

  update-mime-database /usr/share/mime 2>/dev/null || true
  for theme in Papirus Adwaita hicolor; do
    [[ -d "/usr/share/icons/$theme" ]] && gtk-update-icon-cache -f "/usr/share/icons/$theme" 2>/dev/null || true
  done

  mkdir -p "/data/home/$DEV_USER/.config/xfce4/xfconf/xfce-perchannel-xml"
  cat > "/data/home/$DEV_USER/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" <<'XFEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="IconThemeName" type="string" value="Papirus"/>
    <property name="ThemeName" type="string" value="Adwaita"/>
  </property>
</channel>
XFEOF
  chown -R "$DEV_USER:$DEV_USER" "/data/home/$DEV_USER/.config"

  date -Is > "$marker"
  log "XFCE icons: Papirus theme + gvfs/mime/thumbnails configured"
}

ensure_pdf_viewer() {
  [[ "$INSTALL_DESKTOP" == "true" ]] || return 0

  local marker="/var/lib/dev-box/pdf-viewer-ready"
  if [[ -f "$marker" ]] && command -v evince &>/dev/null; then
    return 0
  fi
  rm -f "$marker"

  log "Installing PDF viewer (evince)..."
  if ! apt-get install -y --no-install-recommends evince; then
    log "ERROR: failed to install evince (check apt sources)"
    return 1
  fi
  if ! command -v evince &>/dev/null; then
    log "ERROR: evince not found after install"
    return 1
  fi

  local home="/data/home/$DEV_USER"
  if command -v xdg-mime &>/dev/null; then
    sudo -u "$DEV_USER" env HOME="$home" USER="$DEV_USER" \
      xdg-mime default org.gnome.Evince.desktop application/pdf
  fi

  mkdir -p /var/lib/dev-box
  date -Is > "$marker"
  log "PDF viewer ready: evince (default for application/pdf)"
}

configure_chinese_input_session() {
  local home="/data/home/$DEV_USER"

  mkdir -p "$home/.config/fcitx5/conf" "$home/.config/autostart"
  if [[ ! -f "$home/.config/fcitx5/profile" ]]; then
    cat > "$home/.config/fcitx5/profile" <<'FPEOF'
[Groups/0]
Name=Default
Default Layout=us

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=
FPEOF
  fi

  cat > "$home/.config/autostart/fcitx5.desktop" <<'FCEOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Exec=fcitx5 -d
Comment=Chinese input method
X-GNOME-Autostart-Phase=Applications
FCEOF

  cat > "$home/.config/autostart/gnome-keyring.desktop" <<'GKEOF'
[Desktop Entry]
Type=Application
Name=GNOME Keyring
Exec=/usr/bin/gnome-keyring-daemon --start --components=pkcs11,secrets,ssh
Comment=Secret storage for Cursor and other apps
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
GKEOF

  cat > "$home/.xsessionrc" <<'XSREOF'
# dev-box-fcitx5 — sourced by startxfce4 (xrdp/XFCE)
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export LANG=en_US.UTF-8
export LC_CTYPE=zh_CN.UTF-8
XSREOF

  cat > "$home/.xsession" <<'XSEOF'
#!/bin/sh
# dev-box-fcitx5 — xrdp session must set IME before startxfce4
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export LANG=en_US.UTF-8
export LC_CTYPE=zh_CN.UTF-8
eval "$(dbus-launch --sh-syntax --exit-with-session)" 2>/dev/null || true
eval "$(/usr/bin/gnome-keyring-daemon --start --components=pkcs11,secrets,ssh 2>/dev/null)" || true
export SSH_AUTH_SOCK
fcitx5 -d 2>/dev/null || true
exec startxfce4
XSEOF
  chmod +x "$home/.xsession"

  local xprofile="$home/.xprofile"
  touch "$xprofile"
  if ! grep -q dev-box-fcitx5 "$xprofile" 2>/dev/null; then
    cat >> "$xprofile" <<'XPEOF'

# dev-box-fcitx5 — Chinese fonts + pinyin in XFCE / xrdp
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export LANG=en_US.UTF-8
export LC_CTYPE=zh_CN.UTF-8
eval "$(dbus-launch --sh-syntax --exit-with-session)" 2>/dev/null || true
eval "$(/usr/bin/gnome-keyring-daemon --start --components=pkcs11,secrets,ssh 2>/dev/null)" || true
export SSH_AUTH_SOCK
fcitx5 -d 2>/dev/null || true
XPEOF
  fi

  if ! grep -q dev-box-keyring "$xprofile" 2>/dev/null; then
    cat >> "$xprofile" <<'XKEOF'

# dev-box-keyring — libsecret backend for Cursor / GitHub auth in xrdp
eval "$(/usr/bin/gnome-keyring-daemon --start --components=pkcs11,secrets,ssh 2>/dev/null)" || true
export SSH_AUTH_SOCK
XKEOF
  fi

  local xsettings="$home/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
  if [[ -f "$xsettings" ]] && ! grep -q 'Noto Sans CJK SC' "$xsettings" 2>/dev/null; then
    sed -i '/<property name="Net"/i\
  <property name="Gtk" type="empty">\
    <property name="FontName" type="string" value="Noto Sans CJK SC 10"/>\
  </property>' "$xsettings"
  fi

  sudo -u "$DEV_USER" im-config -n fcitx5 2>/dev/null || true

  local rc="$home/.bashrc"
  touch "$rc"
  if ! grep -q dev-box-locale "$rc" 2>/dev/null; then
    cat >> "$rc" <<'BREOF'

# dev-box-locale — UTF-8 + Chinese ctype for SSH terminal / Cursor
export LANG=en_US.UTF-8
export LC_CTYPE=zh_CN.UTF-8
BREOF
  fi

  chown -R "$DEV_USER:$DEV_USER" "$home/.xsession" "$home/.xsessionrc" "$home/.xprofile" "$home/.config" "$rc"
}

setup_chinese_locale_and_input() {
  [[ "$INSTALL_DESKTOP" == "true" ]] || return 0

  if ! dpkg -s fcitx5-module-xorg &>/dev/null || ! command -v fcitx5 &>/dev/null \
      || ! locale -a 2>/dev/null | grep -qi 'zh_CN.utf8' \
      || ! fc-match 'Noto Sans CJK SC' &>/dev/null; then
    log "Installing Chinese locale, fonts, and fcitx5 pinyin input..."

    apt-get install -y --no-install-recommends \
      locales language-pack-zh-hans \
      fonts-noto-cjk fonts-noto-cjk-extra \
      fcitx5 fcitx5-chinese-addons fcitx5-config-qt \
      fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 \
      fcitx5-module-xorg im-config dbus-x11

    if ! locale -a 2>/dev/null | grep -qi 'zh_CN.utf8'; then
      grep -q 'zh_CN.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null \
        || echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen
      locale-gen zh_CN.UTF-8
    fi
  fi

  configure_chinese_input_session

  mkdir -p /var/lib/dev-box
  date -Is > /var/lib/dev-box/chinese-ime-ready
  log "Chinese ready: Noto CJK fonts, zh_CN.UTF-8, fcitx5 pinyin (Ctrl+Space to switch IME)"
}

configure_xrdp_ini() {
  local ini=/etc/xrdp/xrdp.ini
  [[ -f "$ini" ]] || return 0

  # xrdp 0.9.17 needs ip= under [Xorg] to reach sesman; 0.10.x leftovers break login.
  if grep -q '^\[Xorg\]' "$ini" && ! awk '/^\[Xorg\]/{f=1; next} /^\[/{f=0} f && /^ip=127\.0\.0\.1$/{found=1; exit} END{exit !found}' "$ini"; then
    awk '
      /^\[Xorg\]/ { in_xorg=1; xorg_ip=0; print; next }
      /^\[/ { in_xorg=0 }
      in_xorg && /^port=-1/ && !xorg_ip { print "ip=127.0.0.1"; xorg_ip=1 }
      { print }
    ' "$ini" > "${ini}.tmp" && mv "${ini}.tmp" "$ini"
    log "xrdp.ini: restored [Xorg] ip=127.0.0.1 for sesman"
  fi

  if [[ "$DESKTOP_RDP_PUBLIC" == "true" ]]; then
    sed -i '/^address=/d' "$ini"
  elif grep -q '^address=' "$ini"; then
    sed -i 's/^address=.*/address=127.0.0.1/' "$ini"
  else
    sed -i '/^\[Globals\]/a address=127.0.0.1' "$ini"
  fi
}

configure_xrdp_sesman() {
  local sesman=/etc/xrdp/sesman.ini
  [[ -f "$sesman" ]] || return 0
  grep -q '^\[Xorg\]' "$sesman" || return 0

  # Only the first param= under [Xorg] is the Xorg binary; the rest are startup flags.
  if awk '/^\[Xorg\]/{f=1; next} /^\[/{f=0} f && /^param=\/usr\/lib\/xorg\/Xorg$/{found=1; exit} END{exit !found}' "$sesman"; then
    return 0
  fi

  awk '
    /^\[Xorg\]/ { in_xorg=1; xorg_param=0; print; next }
    /^\[/ { in_xorg=0 }
    in_xorg && /^param=/ {
      if (!xorg_param) { print "param=/usr/lib/xorg/Xorg"; xorg_param=1; next }
    }
    { print }
  ' "$sesman" > "${sesman}.tmp" && mv "${sesman}.tmp" "$sesman"
  log "sesman.ini: Xorg backend -> /usr/lib/xorg/Xorg"
}

configure_desktop_scroll_prefs() {
  [[ "$INSTALL_DESKTOP" == "true" ]] || return 0

  if [[ -x /opt/firefox/firefox ]]; then
    mkdir -p /opt/firefox/distribution
    cat > /opt/firefox/distribution/policies.json <<'FPEOF'
{
  "policies": {
    "Preferences": {
      "mousewheel.default.delta_multiplier_y": {"Value": 40, "Status": "default"},
      "mousewheel.min_line_scroll_amount": {"Value": 1, "Status": "default"}
    }
  }
}
FPEOF
  fi

  if [[ "$INSTALL_CURSOR" == "true" ]]; then
    local home="/data/home/$DEV_USER"
    local settings="$home/.config/Cursor/User/settings.json"
    mkdir -p "$(dirname "$settings")"
    python3 - "$settings" <<'PY'
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
data["editor.mouseWheelScrollSensitivity"] = 0.35
data["terminal.integrated.mouseWheelScrollSensitivity"] = 0.35
data["workbench.list.mouseWheelScrollSensitivity"] = 0.5
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    chown -R "$DEV_USER:$DEV_USER" "$home/.config/Cursor"
  fi
}

ensure_xrdp_touchpad_scroll() {
  [[ "$INSTALL_DESKTOP" == "true" ]] || return 0
  command -v xrdp &>/dev/null || return 0

  configure_xrdp_ini
  configure_xrdp_sesman
  configure_desktop_scroll_prefs

  # Keep apt xrdp/xorgxrdp in sync — source upgrades easily leave mixed versions
  # (xrdp 0.10.x + xorgxrdp 0.2.x breaks RandR / session start).
  if ! dpkg -s xrdp xorgxrdp &>/dev/null; then
    return 0
  fi
  if ! xrdp --version 2>&1 | grep -qF "$(dpkg-query -W -f='${Version}' xrdp 2>/dev/null | sed 's/-.*//')"; then
    log "Reconciling xrdp with apt packages (mixed install detected)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --reinstall xrdp xorgxrdp
    configure_xrdp_ini
    configure_xrdp_sesman
    systemctl restart xrdp xrdp-sesman 2>/dev/null || systemctl restart xrdp
  fi
}

setup_desktop() {
  [[ "$INSTALL_DESKTOP" == "true" ]] || return 0

  ensure_desktop_browser
  ensure_xfce_icons
  ensure_pdf_viewer
  setup_chinese_locale_and_input

  local marker="/var/lib/dev-box/desktop-ready"
  local xsession="/data/home/$DEV_USER/.xsession"
  local desktop_installed=false

  if [[ -f "$marker" ]] && systemctl is-active --quiet xrdp 2>/dev/null \
      && [[ -x "$xsession" ]] && dpkg -s xorgxrdp &>/dev/null \
      && grep -q 'DefaultWindowManager=startwm.sh' /etc/xrdp/sesman.ini 2>/dev/null; then
    desktop_installed=true
  fi

  if [[ "$desktop_installed" == "true" ]]; then
    log "Desktop (XFCE + xrdp) already installed"
    ensure_xrdp_touchpad_scroll || true
    return 0
  fi

  log "Installing XFCE + xrdp remote desktop..."

  if ! swapon --show 2>/dev/null | grep -q .; then
    if [[ ! -f /swapfile ]]; then
      log "Adding 1GB swap for desktop session..."
      fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
    fi
  fi

  apt-get install -y --no-install-recommends \
    xfce4 xfce4-goodies xrdp xorgxrdp dbus-x11 thunar thunar-volman

  adduser xrdp ssl-cert 2>/dev/null || true
  adduser "$DEV_USER" ssl-cert 2>/dev/null || true

  # Ubuntu 22.04 xrdp 黑屏修复：xorgxrdp + .xsession + startwm.sh 清环境变量
  configure_chinese_input_session

  if ! grep -q 'dev-box-startwm' /etc/xrdp/startwm.sh 2>/dev/null; then
    sed -i '1a\
# dev-box-startwm\
unset DBUS_SESSION_BUS_ADDRESS\
unset XDG_RUNTIME_DIR' /etc/xrdp/startwm.sh
  fi

  # 勿改 DefaultWindowManager=startxfce4（xrdp 会找 /etc/xrdp/startxfce4，不存在则黑屏）
  if grep -q '^DefaultWindowManager=' /etc/xrdp/sesman.ini; then
    sed -i 's|^DefaultWindowManager=.*|DefaultWindowManager=startwm.sh|' /etc/xrdp/sesman.ini
  fi

  if [[ -n "$DEV_RDP_PASSWORD_B64" ]]; then
    echo "$DEV_USER:$(echo "$DEV_RDP_PASSWORD_B64" | base64 -d)" | chpasswd
    log "RDP password configured from dev_rdp_password"
  else
    log "RDP: dev_rdp_password not set — run: sudo passwd $DEV_USER"
  fi

  if [[ "$DESKTOP_RDP_PUBLIC" == "true" ]]; then
    log "RDP listening on all interfaces :3389 (desktop_rdp_public=true)"
  else
    log "RDP bound to 127.0.0.1:3389 — connect via SSH tunnel + Windows App"
  fi
  configure_xrdp_ini

  systemctl enable xrdp
  systemctl restart xrdp

  ensure_xrdp_touchpad_scroll || true

  mkdir -p /var/lib/dev-box
  date -Is > "$marker"
  log "Desktop ready: Windows App -> 127.0.0.1:3389 (session=Xorg), user $DEV_USER, browser=firefox, cursor=$INSTALL_CURSOR"
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

mark_setup_complete() {
  mkdir -p /var/lib/dev-box
  local iid
  iid=$(curl -sf http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo unknown)
  cat > /var/lib/dev-box/setup-complete <<EOF
instance_id=$iid
completed_at=$(date -Is)
install_desktop=$${INSTALL_DESKTOP}
EOF
  date -Is > /data/.initialized
  log "Setup complete (instance $iid)"
}

# ---- main ----
log "Starting dev-box setup"
setup_dev_user
setup_ssh_hardening

if dev=$(wait_for_data_device); then
  mount_data_volume "$dev"
  setup_packages
  setup_autostop
  mark_setup_complete
else
  log "WARN: data volume not found yet; SSH ready, run: sudo /usr/local/bin/dev-box-setup.sh"
fi
