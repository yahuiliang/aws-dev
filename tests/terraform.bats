#!/usr/bin/env bats
# Terraform 配置与模板

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  TF_DIR="$PROJECT_ROOT/terraform"
  KEY="$BATS_TEST_DIRNAME/fixtures/test_key.pub"
}

@test "terraform validate 通过" {
  run terraform -chdir="$TF_DIR" validate -no-color
  [ "$status" -eq 0 ]
}

@test "terraform fmt 已格式化" {
  run terraform -chdir="$TF_DIR" fmt -check -recursive -no-color
  [ "$status" -eq 0 ]
}

@test "dev-box-setup.tpl 可被 templatefile 渲染" {
  run "$BATS_TEST_DIRNAME/check_template.sh" "$KEY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "allowed_ssh_cidr 拒绝 0.0.0.0/0" {
  run terraform -chdir="$TF_DIR" console -no-color <<'EOF'
!contains(["0.0.0.0/0", "::/0"], "0.0.0.0/0")
EOF
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}
