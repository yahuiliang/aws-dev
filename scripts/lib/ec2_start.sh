#!/usr/bin/env bash
# Spot 实例 start 辅助（供 start.sh 使用，可单测）

is_incorrect_spot_request_state() {
  grep -q 'IncorrectSpotRequestState' <<<"$1"
}

# 实例与 Spot 请求处于可 start 状态（或已在启动中）
spot_startable_states() {
  local instance_state="$1"
  local spot_request_state="$2"

  case "$instance_state" in
    running | pending) return 0 ;;
    stopped)
      [[ "$spot_request_state" == "disabled" ]] && return 0
      ;;
  esac
  return 1
}

start_instance_with_spot_retry() {
  local instance_id="$1"
  local timeout="${2:-120}"
  local poll="${3:-5}"
  local elapsed=0 err

  while true; do
    if err=$(aws ec2 start-instances --instance-ids "$instance_id" 2>&1); then
      printf '%s\n' "$err"
      return 0
    fi
    if is_incorrect_spot_request_state "$err"; then
      if (( elapsed >= timeout )); then
        echo "$err" >&2
        echo "→ Spot 请求仍未就绪，无法 start（已等 ${timeout}s）" >&2
        return 1
      fi
      echo "  Spot 请求状态切换中，${poll}s 后重试..."
      sleep "$poll"
      elapsed=$((elapsed + poll))
      continue
    fi
    echo "$err" >&2
    return 1
  done
}
