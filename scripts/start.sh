#!/usr/bin/env bash
# 启动已停止的 Spot 实例；等待 Spot 就绪、刷新公网 IP、更新 SSH config
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
SPOT_WAIT_TIMEOUT="${START_SPOT_WAIT_TIMEOUT:-120}"
RUN_WAIT_TIMEOUT="${START_RUNNING_WAIT_TIMEOUT:-300}"
POLL="${START_POLL:-5}"

# shellcheck source=lib/ec2_start.sh
source "$ROOT/scripts/lib/ec2_start.sh"

cd "$TF_DIR"
ID=$(terraform output -raw instance_id)

describe_state() {
  aws ec2 describe-instances --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

describe_spot_request_state() {
  local sir
  sir=$(aws ec2 describe-instances --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].SpotInstanceRequestId' --output text)
  if [[ -z "$sir" || "$sir" == "None" ]]; then
    echo "none"
    return 0
  fi
  aws ec2 describe-spot-instance-requests --spot-instance-request-ids "$sir" \
    --query 'SpotInstanceRequests[0].State' --output text
}

wait_for_spot_startable() {
  local elapsed=0 inst req
  while (( elapsed < SPOT_WAIT_TIMEOUT )); do
    inst=$(describe_state)
    req=$(describe_spot_request_state)
    if spot_startable_states "$inst" "$req"; then
      return 0
    fi
    echo "  等待 Spot 就绪 (${req}/${inst})..."
    sleep "$POLL"
    elapsed=$((elapsed + POLL))
  done
  echo "→ Spot 请求超时未就绪（${SPOT_WAIT_TIMEOUT}s）" >&2
  return 1
}

wait_for_running() {
  local elapsed=0 state
  while (( elapsed < RUN_WAIT_TIMEOUT )); do
    state=$(describe_state)
    if [[ "$state" == "running" ]]; then
      return 0
    fi
    if [[ "$state" == "terminated" || "$state" == "shutting-down" ]]; then
      echo "→ 实例已终止，请运行 make restart 重建" >&2
      return 1
    fi
    sleep "$POLL"
    elapsed=$((elapsed + POLL))
  done
  echo "→ 实例未在 ${RUN_WAIT_TIMEOUT}s 内进入 running" >&2
  return 1
}

state=$(describe_state)

if [[ "$state" == "stopping" ]]; then
  echo "→ 实例 $ID 仍在停止，等待 stopped..."
  aws ec2 wait instance-stopped --instance-ids "$ID"
  state=stopped
fi

case "$state" in
  running)
    echo "实例 $ID 已在运行"
    ;;
  pending)
    echo "实例 $ID 正在启动..."
    wait_for_running
    ;;
  stopped)
    echo "→ 启动实例 $ID ..."
    wait_for_spot_startable
    start_instance_with_spot_retry "$ID" "$SPOT_WAIT_TIMEOUT" "$POLL"
    echo "→ 等待实例 running ..."
    wait_for_running
    ;;
  terminated | shutting-down)
    echo "→ 实例已终止，请运行 make restart 重建" >&2
    exit 1
    ;;
  *)
    echo "→ 实例状态异常: $state" >&2
    exit 1
    ;;
esac

echo "→ 刷新公网 IP ..."
terraform apply -refresh-only -auto-approve -input=false >/dev/null

IP=$(terraform output -raw public_ip)
"$ROOT/scripts/vscode-ssh.sh"

echo "✓ 实例已就绪"
echo "  IP: $IP"
echo "  Cursor: 连接 Host aws-vibe-dev"
