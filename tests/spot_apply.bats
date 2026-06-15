#!/usr/bin/env bats
# Spot fallback 与 tfvars 列表解析

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/lib/tfvars.sh"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/lib/spot_apply.sh"
  TFVARS=$(mktemp)
  cp "$BATS_TEST_DIRNAME/fixtures/sample.tfvars" "$TFVARS"
  TFVARS_FILE="$TFVARS"
}

teardown() {
  rm -f "$TFVARS"
}

@test "tfvar_list 读取字符串列表" {
  items=()
  while IFS= read -r item; do
    items+=("$item")
  done < <(tfvar_list instance_type_fallbacks)
  [ "${#items[@]}" -eq 2 ]
  [ "${items[0]}" = "t4g.small" ]
  [ "${items[1]}" = "t4g.medium" ]
}

@test "tfvar_list 空列表不输出条目" {
  sed -i '' 's/instance_type_fallbacks = .*/instance_type_fallbacks = []/' "$TFVARS"
  items=()
  while IFS= read -r item; do
    items+=("$item")
  done < <(tfvar_list instance_type_fallbacks)
  [ "${#items[@]}" -eq 0 ]
}

@test "spot_instance_types 首选在前且去重" {
  sed -i '' 's/instance_type      = "t4g.micro"/instance_type      = "t4g.small"/' "$TFVARS"
  sed -i '' 's/instance_type_fallbacks = .*/instance_type_fallbacks = ["t4g.small", "t4g.medium"]/' "$TFVARS"
  types=()
  while IFS= read -r type; do
    types+=("$type")
  done < <(spot_instance_types "$(tfvar instance_type)")
  [ "${#types[@]}" -eq 2 ]
  [ "${types[0]}" = "t4g.small" ]
  [ "${types[1]}" = "t4g.medium" ]
}

@test "spot_instance_types 未配置 fallbacks 时使用默认" {
  grep -v instance_type_fallbacks "$TFVARS" > "${TFVARS}.tmp"
  mv "${TFVARS}.tmp" "$TFVARS"
  sed -i '' 's/instance_type      = "t4g.micro"/instance_type      = "t4g.small"/' "$TFVARS"
  types=()
  while IFS= read -r type; do
    types+=("$type")
  done < <(spot_instance_types "$(tfvar instance_type)")
  [ "${#types[@]}" -eq 3 ]
  [ "${types[0]}" = "t4g.small" ]
  [ "${types[1]}" = "t4g.micro" ]
  [ "${types[2]}" = "t4g.medium" ]
}

@test "is_spot_capacity_error 识别容量错误" {
  log=$(mktemp)
  echo "capacity-not-available" > "$log"
  is_spot_capacity_error "$log"
  echo "There is no Spot capacity available that matches your request." > "$log"
  is_spot_capacity_error "$log"
  rm -f "$log"
}

@test "is_spot_capacity_error 忽略其他错误" {
  log=$(mktemp)
  echo "Error: AccessDenied" > "$log"
  run is_spot_capacity_error "$log"
  [ "$status" -eq 1 ]
  rm -f "$log"
}
