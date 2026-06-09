#!/usr/bin/env bash
# 用与 main.tf 相同的 templatefile 参数渲染 dev-box-setup.sh.tpl
set -euo pipefail

render_dev_box_setup() {
  local tf_dir="$1"
  local pub_path install_docker idle_min auto_stop_b64

  pub_path=$(tfvar ssh_public_key_path "~/.ssh/id_rsa.pub")
  pub_path="${pub_path/#\~/$HOME}"
  install_docker=$(tfvar install_docker false)
  idle_min=$(tfvar auto_stop_idle_minutes 0)

  if [[ "$idle_min" -gt 0 ]]; then
    auto_stop_b64='base64encode(file("files/auto-stop.sh"))'
  else
    auto_stop_b64='""'
  fi

  terraform -chdir="$tf_dir" console -no-color <<< \
    "templatefile(\"files/dev-box-setup.sh.tpl\", { dev_username = \"$(tfvar dev_username dev)\", install_docker = ${install_docker}, ssh_public_key = chomp(file(\"${pub_path}\")), auto_stop_idle_minutes = $(tfvar auto_stop_idle_minutes 120), auto_stop_check_interval_minutes = $(tfvar auto_stop_check_interval_minutes 5), aws_region = \"$(tfvar aws_region us-west-2)\", auto_stop_script_b64 = ${auto_stop_b64}, block_ssh_until_ready = $(tfvar block_ssh_until_ready true) })" \
    | awk '/^<<EOT$/{flag=1;next} /^EOT$/{flag=0;next} flag'
}
