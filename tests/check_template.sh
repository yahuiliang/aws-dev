#!/usr/bin/env bash
# 验证 dev-box-setup.sh.tpl 可被 Terraform templatefile 渲染
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="$ROOT/terraform"
KEY="${1:-$ROOT/tests/fixtures/test_key.pub}"

ARGS="{ dev_username = \"dev\", install_docker = true, ssh_public_key = chomp(file(\"${KEY}\")), auto_stop_idle_minutes = 30, auto_stop_check_interval_minutes = 5, aws_region = \"us-west-2\", auto_stop_script_b64 = base64encode(file(\"files/auto-stop.sh\")), block_ssh_until_ready = true }"

LEN=$(terraform -chdir="$TF" console -no-color <<< "length(templatefile(\"files/dev-box-setup.sh.tpl\", ${ARGS}))" | tr -d '[:space:]')
[[ "$LEN" =~ ^[0-9]+$ ]] || { echo "templatefile 返回非数字: $LEN"; exit 1; }
[[ "$LEN" -gt 1000 ]] || { echo "渲染结果过短: $LEN bytes"; exit 1; }

HAS_DEFAULT=$(terraform -chdir="$TF" console -no-color <<< "strcontains(templatefile(\"files/dev-box-setup.sh.tpl\", ${ARGS}), \"\$\${AUTO_STOP_IDLE:-0}\")" | tr -d '[:space:]')
[[ "$HAS_DEFAULT" == "true" ]] || { echo "缺少 bash 默认值语法 (\${AUTO_STOP_IDLE:-0})"; exit 1; }

echo "OK: template rendered ($LEN bytes)"
