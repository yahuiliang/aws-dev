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

@test "tfvar 缺失时使用默认值" {
  [ "$(tfvar nonexistent_key fallback)" = "fallback" ]
}

@test "update_allowed_ssh_cidr 正确替换 /32 且不破坏行" {
  update_allowed_ssh_cidr "$TFVARS" "96.74.107.150/32"
  grep -q 'allowed_ssh_cidr    = "96.74.107.150/32"' "$TFVARS"
  ! grep -q '1.2.3.4/32' "$TFVARS"
}
