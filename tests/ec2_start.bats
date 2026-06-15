#!/usr/bin/env bats

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/scripts/lib/ec2_start.sh"
}

@test "is_incorrect_spot_request_state 识别 Spot 状态错误" {
  run is_incorrect_spot_request_state "IncorrectSpotRequestState: cannot start"
  [ "$status" -eq 0 ]
  run is_incorrect_spot_request_state "SomeOtherError"
  [ "$status" -eq 1 ]
}

@test "spot_startable_states stopped+disabled 可 start" {
  run spot_startable_states stopped disabled
  [ "$status" -eq 0 ]
}

@test "spot_startable_states stopped+active 不可 start" {
  run spot_startable_states stopped active
  [ "$status" -eq 1 ]
}

@test "spot_startable_states running 已就绪" {
  run spot_startable_states running active
  [ "$status" -eq 0 ]
}
