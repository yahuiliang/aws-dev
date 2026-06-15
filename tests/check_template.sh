#!/usr/bin/env bash
# 验证 dev-box-setup.sh.tpl 可被 Terraform templatefile 渲染
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="$ROOT/terraform"
KEY="${1:-$ROOT/tests/fixtures/test_key.pub}"

ARGS="{ dev_username = \"dev\", install_docker = true, install_desktop = true, install_cursor = true, desktop_rdp_public = false, dev_rdp_password_b64 = \"\", ssh_public_key = chomp(file(\"${KEY}\")), auto_stop_idle_minutes = 30, auto_stop_check_interval_minutes = 5, aws_region = \"us-west-2\", auto_stop_script_b64 = base64encode(file(\"files/auto-stop.sh\")), block_ssh_until_ready = true }"

LEN=$(terraform -chdir="$TF" console -no-color <<< "length(templatefile(\"files/dev-box-setup.sh.tpl\", ${ARGS}))" | tr -d '[:space:]')
[[ "$LEN" =~ ^[0-9]+$ ]] || { echo "templatefile 返回非数字: $LEN"; exit 1; }
[[ "$LEN" -gt 1000 ]] || { echo "渲染结果过短: $LEN bytes"; exit 1; }

HAS_DEFAULT=$(terraform -chdir="$TF" console -no-color <<< "strcontains(templatefile(\"files/dev-box-setup.sh.tpl\", ${ARGS}), \"\$\${AUTO_STOP_IDLE:-0}\")" | tr -d '[:space:]')
[[ "$HAS_DEFAULT" == "true" ]] || { echo "缺少 bash 默认值语法 (\${AUTO_STOP_IDLE:-0})"; exit 1; }

# user-data gzip 压缩后须 < 16KB（EC2 限制）
GZIP_BYTES=$(terraform -chdir="$TF" console -no-color <<EOF | python3 -c "import sys,base64; print(len(base64.b64decode(sys.stdin.read().strip())))"
base64gzip(templatefile("user-data.sh.tpl", { setup_script = templatefile("files/dev-box-setup.sh.tpl", ${ARGS}) }))
EOF
)
[[ "$GZIP_BYTES" =~ ^[0-9]+$ ]] || { echo "gzip 大小计算失败: $GZIP_BYTES"; exit 1; }
[[ "$GZIP_BYTES" -lt 16384 ]] || { echo "user-data gzip 过大: ${GZIP_BYTES} bytes (max 16384)"; exit 1; }

echo "OK: template rendered ($LEN bytes), user-data gzip ${GZIP_BYTES} bytes"
