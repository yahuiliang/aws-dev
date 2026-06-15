#!/usr/bin/env bash
# Spot 容量不足时按 instance_type 列表依次重试 terraform apply

is_spot_capacity_error() {
  grep -qiE "capacity-not-available|no Spot capacity available" "$1"
}

# 首选 instance_type + fallbacks，去重且保持顺序
spot_instance_types() {
  local primary="$1"
  local type
  local seen="|${primary}|"
  local fallbacks=()

  if grep -qE "^[[:space:]]*instance_type_fallbacks[[:space:]]*=" "${TFVARS_FILE:?TFVARS_FILE 未设置}"; then
    while IFS= read -r fb; do
      fallbacks+=("$fb")
    done < <(tfvar_list instance_type_fallbacks)
  else
    # tfvars 未配置时与 variables.tf 默认一致
    fallbacks=("t4g.micro" "t4g.medium")
  fi

  echo "$primary"
  for type in "${fallbacks[@]}"; do
    [[ -z "$type" ]] && continue
    [[ "$seen" == *"|${type}|"* ]] && continue
    echo "$type"
    seen="${seen}${type}|"
  done
}

spot_apply_with_fallback() {
  local tf_dir="$1"
  shift
  local extra_args=("$@")
  local log types=() type rc primary

  primary=$(tfvar instance_type "t4g.micro")
  types=()
  while IFS= read -r type; do
    types+=("$type")
  done < <(spot_instance_types "$primary")

  log=$(mktemp)
  trap 'rm -f "$log"' RETURN

  for type in "${types[@]}"; do
    echo "→ 尝试 Spot instance_type=${type} ..."
    set +e
    terraform -chdir="$tf_dir" apply -auto-approve -var="instance_type=${type}" ${extra_args+"${extra_args[@]}"} 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e

    if [[ $rc -eq 0 ]]; then
      if [[ "$primary" != "$type" ]]; then
        echo "→ 已用 fallback 规格 ${type}（tfvars 首选仍为 ${primary}）"
      fi
      return 0
    fi

    if is_spot_capacity_error "$log"; then
      echo "→ ${type} 当前无 Spot 容量，尝试下一个规格..."
      terraform -chdir="$tf_dir" taint -allow-missing aws_spot_instance_request.dev 2>/dev/null || true
      continue
    fi

    return "$rc"
  done

  echo "→ 所有 instance type 均无 Spot 容量: ${types[*]}"
  return 1
}
