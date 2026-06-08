#!/usr/bin/env bash
# dev 用户通过 nvm 装 Node 包（避免 apt 的 npm 写 /usr/local 报 EACCES）

NVM_INSTALL_URL='https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh'
# leetcode-cli 依赖较旧，Node 24 会报 padLevels 警告；固定 Node 20
NVM_NODE_VERSION='20'

# t4g.micro 装 Node 容易 OOM，临时加 swap
ensure_swap_if_needed() {
  if swapon --show 2>/dev/null | grep -q .; then
    return 0
  fi
  local mem_mb
  mem_mb=$(free -m | awk '/^Mem:/{print $2}')
  if [[ "${mem_mb:-0}" -lt 1800 ]] && [[ ! -f /swapfile ]]; then
    echo "==> 添加 1GB swap（小内存实例装 Node 需要）..."
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
  fi
}

_dev_nvm_shell() {
  local dev_user="${1:-dev}"
  shift
  local script="$1"
  sudo -u "$dev_user" bash -lc "$script"
}

ensure_dev_nvm() {
  local dev_user="${1:-dev}"
  ensure_swap_if_needed 2>/dev/null || sudo bash -c "$(declare -f ensure_swap_if_needed); ensure_swap_if_needed" || true

  _dev_nvm_shell "$dev_user" '
    set -euo pipefail
    export NVM_DIR="$HOME/.nvm"
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
      curl -fsSL "'"$NVM_INSTALL_URL"'" | bash
    fi
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"

    nvm install '"$NVM_NODE_VERSION"'
    nvm alias default '"$NVM_NODE_VERSION"'
    nvm use '"$NVM_NODE_VERSION"'

    npm config delete prefix 2>/dev/null || true
    export PATH="$(dirname "$(nvm which current)"):$PATH"

    echo "node: $(node -v) @ $(command -v node)"
    echo "npm:  $(npm -v) @ $(command -v npm)"
    if [[ "$(command -v npm)" != "$NVM_DIR"* ]]; then
      echo "ERROR: npm 仍指向系统路径，中止" >&2
      exit 1
    fi

    grep -q NODE_OPTIONS "$HOME/.bashrc" 2>/dev/null || \
      echo "export NODE_OPTIONS=\"--no-warnings\"" >> "$HOME/.bashrc"
  '
}

install_leetcode_wrapper() {
  local dev_user="${1:-dev}"
  sudo tee /usr/local/bin/leetcode > /dev/null <<EOF
#!/bin/bash
export NVM_DIR="/data/home/${dev_user}/.nvm"
export NODE_OPTIONS="--no-warnings"
if [[ -s "\$NVM_DIR/nvm.sh" ]]; then
  . "\$NVM_DIR/nvm.sh"
  nvm use 20 >/dev/null 2>&1 || true
fi
exec "\$(command -v leetcode)" "\$@"
EOF
  sudo chmod +x /usr/local/bin/leetcode
  echo "Installed /usr/local/bin/leetcode"
}

dev_install_leetcode_cli() {
  local dev_user="${1:-dev}"
  ensure_dev_nvm "$dev_user"

  _dev_nvm_shell "$dev_user" '
    set -euo pipefail
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm use '"$NVM_NODE_VERSION"'
    export PATH="$(dirname "$(nvm which current)"):$PATH"

    major="$(node -v | cut -d. -f1 | tr -d v)"
    if [[ "$major" != "'"$NVM_NODE_VERSION"'" ]]; then
      echo "ERROR: 需要 Node '"$NVM_NODE_VERSION"'，当前 $(node -v)" >&2
      exit 1
    fi

    npm install -g leetcode-cli
    echo "node:     $(node -v)"
    echo "leetcode: $(command -v leetcode)"
  '
  install_leetcode_wrapper "$dev_user"
}

dev_leetcode_cmd() {
  local dev_user="${1:-dev}"
  shift
  local cmd="$*"
  _dev_nvm_shell "$dev_user" "
    set -euo pipefail
    export NVM_DIR=\"\$HOME/.nvm\"
    # shellcheck disable=SC1091
    . \"\$NVM_DIR/nvm.sh\"
    nvm use $NVM_NODE_VERSION
    export PATH=\"\$(dirname \"\$(nvm which current)\"):\$PATH\"
    $cmd
  "
}
