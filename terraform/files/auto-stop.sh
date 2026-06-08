#!/bin/bash
# 空闲检测：连续 N 次检查均空闲则自动 stop 本实例（需 IAM 实例角色）
set -euo pipefail

IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-30}"
CHECK_INTERVAL_MINUTES="${CHECK_INTERVAL_MINUTES:-5}"
BOOT_GRACE_MINUTES="${BOOT_GRACE_MINUTES:-15}"
STREAK_FILE="/var/lib/dev-box/idle-streak"
REGION="${AWS_REGION:-us-west-2}"

log() { logger -t auto-stop "$*"; echo "[auto-stop] $*"; }

idle_threshold_seconds=$((IDLE_THRESHOLD_MINUTES * 60))
required_streak=$((IDLE_THRESHOLD_MINUTES / CHECK_INTERVAL_MINUTES))

# 启动宽限期，避免 cloud-init / apt 期间误停
uptime_secs=$(cut -d. -f1 /proc/uptime)
if (( uptime_secs < BOOT_GRACE_MINUTES * 60 )); then
  exit 0
fi

idle_to_seconds() {
  local idle="$1"
  case "$idle" in
    .|-) echo 0 ;;
    old|*days*) echo "$idle_threshold_seconds" ;;
    *:*)
      local mins secs
      mins="${idle%%:*}"
      secs="${idle##*:}"
      echo $((10#mins * 60 + 10#secs))
      ;;
    *) echo 0 ;;
  esac
}

has_active_ssh() {
  local who_line idle idle_secs
  while IFS= read -r who_line; do
    [[ -z "$who_line" ]] && continue
    idle=$(echo "$who_line" | awk '{print $5}')
    idle_secs=$(idle_to_seconds "$idle")
    if (( idle_secs < idle_threshold_seconds )); then
      return 0
    fi
  done < <(who -u 2>/dev/null)

  return 1
}

is_cpu_busy() {
  local nproc load1
  nproc=$(nproc)
  load1=$(awk '{print $1}' /proc/loadavg)
  awk -v load="$load1" -v n="$nproc" 'BEGIN { exit !(load > n * 0.12) }'
}

has_docker_workload() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps -q 2>/dev/null | grep -q .
}

has_keepalive() {
  [[ -f /var/lib/dev-box/keepalive ]] || return 1
  find /var/lib/dev-box/keepalive -mmin "-${IDLE_THRESHOLD_MINUTES}" 2>/dev/null | grep -q .
}

is_active() {
  has_keepalive && return 0
  has_active_ssh && return 0
  is_cpu_busy && return 0
  has_docker_workload && return 0
  return 1
}

stop_instance() {
  local instance_id
  instance_id=$(curl -sf http://169.254.169.254/latest/meta-data/instance-id)
  log "Idle for ${IDLE_THRESHOLD_MINUTES} minutes — stopping instance $instance_id"
  aws ec2 stop-instances --region "$REGION" --instance-ids "$instance_id"
}

mkdir -p /var/lib/dev-box
streak=0
[[ -f "$STREAK_FILE" ]] && streak=$(cat "$STREAK_FILE")

if is_active; then
  streak=0
  log "Activity detected, reset idle streak"
else
  streak=$((streak + 1))
  log "No activity (${streak}/${required_streak} checks, every ${CHECK_INTERVAL_MINUTES}m)"
fi

echo "$streak" > "$STREAK_FILE"

if (( streak >= required_streak )); then
  stop_instance
fi
