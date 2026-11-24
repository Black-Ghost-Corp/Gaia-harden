#!/usr/bin/env bats
# Module selection: --modules, GAIA_MODULES, the interactive menu and "not selected" steps.

load test_helper

@test "without modules, the base runs and the modules are 'not selected'" {
  gaia --dry-run
  assert_success
  assert_status ssh 'would change'
  assert_status docker 'not selected'
  assert_status caddy 'not selected'
}

@test "--modules docker runs the docker module only" {
  gaia --dry-run --modules docker
  assert_success
  assert_status docker 'would change'
  assert_status caddy 'not selected'
}

@test "GAIA_MODULES in gaia.conf chooses the modules; --modules wins over it" {
  conf 'GAIA_MODULES="caddy"'
  gaia --dry-run
  assert_success
  assert_status caddy 'would change'
  assert_status docker 'not selected'
  gaia --dry-run --modules docker
  assert_status docker 'would change'
  assert_status caddy 'not selected'
}

@test "accepts commas, spaces, upper case and 'all'; 'none' selects nothing" {
  gaia --dry-run --modules 'Caddy, DOCKER'
  assert_success
  assert_output --partial 'modules="docker caddy"'
  gaia --dry-run --modules all
  assert_output --partial 'modules="docker caddy"'
  gaia --dry-run --modules none
  assert_output --partial 'modules=none'
}

@test "an unknown module is refused before any step runs" {
  gaia --modules docker,kubernetes
  assert_failure 2
  assert_output --partial "unknown module in GAIA_MODULES: 'kubernetes'"
  refute_called 'apt-get'
}

@test "--only ignores the module selection" {
  gaia --dry-run --only docker
  assert_success
  assert_status docker 'would change'
}

@test "menu: with a terminal and nothing chosen, asks; Enter means none" {
  tty_answers '' y
  run bash "$REPO/bootstrap.sh" --config "$CONF" --dry-run
  assert_success
  assert_output --partial 'Optional modules'
  assert_status docker 'not selected'
}

@test "menu: numbers and names separated by commas" {
  tty_answers '1, caddy'
  run bash "$REPO/bootstrap.sh" --config "$CONF" --dry-run
  assert_success
  assert_status docker 'would change'
  assert_status caddy 'would change'
}

@test "menu: an invalid answer exits with 2" {
  tty_answers 'nope'
  run bash "$REPO/bootstrap.sh" --config "$CONF" --dry-run
  assert_failure 2
  assert_output --partial "unknown module in menu answer: 'nope'"
}

@test "menu: asks the administrator name when nothing set it" {
  printf 'GAIA_ADMIN_SSH_KEYS="%s"\n' "$PUBKEY" >"$CONF"
  # Order of the questions: administrator, then modules.
  tty_answers deploy ''
  run bash "$REPO/bootstrap.sh" --config "$CONF" --dry-run
  assert_success
  assert_output --partial 'admin=deploy'
}
