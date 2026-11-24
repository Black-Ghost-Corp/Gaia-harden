#!/usr/bin/env bats
# Custom steps: executables in GAIA_EXTRA_STEPS_DIR, same log, dry-run and status contract.

load test_helper

custom() {
  local name=$1 body=$2
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  printf '#!/usr/bin/env bash\n# gaia-description: custom %s\n# shellcheck source=/dev/null\nsource "$GAIA_LIB_DIR/common.sh"\ngaia_step_mode\n%s\n' \
    "$name" "$body" >"$BATS_TEST_TMPDIR/custom/$name.sh"
  chmod +x "$BATS_TEST_TMPDIR/custom/$name.sh"
}

setup_custom() {
  conf "GAIA_EXTRA_STEPS_DIR=$BATS_TEST_TMPDIR/custom"
}

@test "run in lexical order, after directories and before the final audit, with the step log" {
  custom 20-second 'gaia_info "I am the second"'
  custom 10-first 'gaia_info "I am the first" dry=$GAIA_DRY_RUN'
  setup_custom
  gaia --only directories,custom:first,custom:second,summary
  assert_success
  assert_output --regexp 'step=directories\] step finished.*
.*step=custom:first\] step started.*
.*\[gaia\]\[info\]\[step=custom:first\] I am the first dry=0.*
.*step=custom:second\] step started.*
.*step=summary\] step started'
}

@test "--list-steps shows them with their description" {
  custom 10-volume 'true'
  setup_custom
  gaia --list-steps
  assert_success
  assert_output --regexp 'custom:volume +custom +custom 10-volume'
}

@test "they get the configuration and the same dry-run; gaia_run does not run in dry-run" {
  custom 10-volume 'gaia_info "admin is $GAIA_ADMIN_USER"; gaia_run docker volume create app-data'
  setup_custom
  gaia --dry-run --only custom:volume
  assert_success
  assert_output --partial '[gaia][info][step=custom:volume] admin is admin'
  assert_output --partial '[dry-run] would run: docker volume create app-data'
  assert_no_mutation
  assert_status custom:volume 'would change'
}

@test "status: done when it changes, ok when not, skipped with gaia_skip" {
  custom 10-change 'gaia_run docker volume create x'
  custom 20-nothing 'gaia_info "nothing to do"'
  custom 30-skip 'gaia_skip "does not apply here"'
  setup_custom
  gaia --only custom:change,custom:nothing,custom:skip
  assert_success
  assert_status custom:change 'done'
  assert_status custom:nothing ok
  assert_status custom:skip skipped
  assert_called '^docker volume create x$'
}

@test "a failure shows the step and line and stops the run" {
  custom 10-broken 'false'
  custom 20-after 'gaia_info "should not run"'
  setup_custom
  gaia --only custom:broken,custom:after
  assert_failure
  assert_output --regexp 'error\]\[step=custom:broken\] command failed .*line=6'
  assert_status custom:broken failed
  assert_status custom:after skipped
  refute_output --partial 'should not run'
}

@test "a file without the executable bit is skipped with a warning" {
  custom 10-noexec 'gaia_info hi'
  chmod -x "$BATS_TEST_TMPDIR/custom/10-noexec.sh"
  setup_custom
  gaia --only custom:noexec
  assert_success
  assert_output --regexp 'warn.*custom step is not executable'
  assert_status custom:noexec skipped
}

@test "--skip works with custom steps" {
  custom 10-volume 'gaia_run docker volume create x'
  setup_custom
  gaia --skip custom:volume --only directories,custom:volume
  assert_success
  assert_status custom:volume skipped
  refute_called 'docker volume'
}
