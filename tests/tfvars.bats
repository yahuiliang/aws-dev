#!/usr/bin/env bats
# tfvars 解析与 CIDR 更新

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/lib/tfvars.sh"
  TFVARS=$(mktemp)
  cp "$BATS_TEST_DIRNAME/fixtures/sample.tfvars" "$TFVARS"
  TFVARS_FILE="$TFVARS"
}

teardown() {
  rm -f "$TFVARS"
}

@test "tfvar 读取字符串变量" {
  [ "$(tfvar aws_region)" = "us-west-2" ]
  [ "$(tfvar dev_username dev)" = "dev" ]
}

@test "tfvar 读取布尔变量" {
  [ "$(tfvar install_docker false)" = "true" ]
  [ "$(tfvar block_ssh_until_ready false)" = "true" ]
}

@test "tfvar 读取数字变量" {
  [ "$(tfvar auto_stop_idle_minutes 99)" = "0" ]
  [ "$(tfvar auto_stop_check_interval_minutes 99)" = "5" ]
}

@test "tfvar 缺失时使用默认值" {
  [ "$(tfvar nonexistent_key fallback)" = "fallback" ]
}

@test "update_allowed_ssh_cidr 正确替换 /32 且不破坏行" {
  update_allowed_ssh_cidr "$TFVARS" "96.74.107.150/32"
  grep -q 'allowed_ssh_cidr    = "96.74.107.150/32"' "$TFVARS"
  ! grep -q '1.2.3.4/32' "$TFVARS"
}

@test "update_dev_rdp_password 写入并转义特殊字符" {
  update_dev_rdp_password "$TFVARS" 'p"a\ss'
  line=$(grep dev_rdp_password "$TFVARS")
  [ "$line" = 'dev_rdp_password    = "p\"a\\ss"' ]
}

@test "update_dev_rdp_password 简单密码可读回" {
  update_dev_rdp_password "$TFVARS" 'my-rdp-secret'
  [ "$(tfvar dev_rdp_password "")" = 'my-rdp-secret' ]
}

@test "update_dev_rdp_password 重复写入会替换旧值" {
  update_dev_rdp_password "$TFVARS" 'first-secret'
  update_dev_rdp_password "$TFVARS" 'second-secret'
  [ "$(grep -c 'dev_rdp_password' "$TFVARS")" -eq 1 ]
  [ "$(tfvar dev_rdp_password "")" = 'second-secret' ]
}
