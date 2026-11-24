#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# Command line: listing, step selection, errors before anything runs, confirmation.

load test_helper

@test "--list-steps lists the steps in order, without root or a config file" {
  STUB_EUID=1000 run bash "$REPO/bootstrap.sh" --list-steps
  assert_success
  assert_line --index 0 --regexp '^ +1  preflight +base'
  assert_output --regexp 'docker +module'
  assert_output --regexp 'caddy +module'
  assert_line --regexp 'summary +base'
  # Base steps (<90) first, then modules, then the final audit and the summary.
  local out=$output
  [[ $out =~ directories.*docker.*caddy.*audit-after.*summary ]]
}

@test "--list-steps includes custom steps between the modules and the final steps" {
  mkdir -p "$BATS_TEST_TMPDIR/extras"
  printf '#!/usr/bin/env bash\n# gaia-description: my step\n' >"$BATS_TEST_TMPDIR/extras/10-mine.sh"
  chmod +x "$BATS_TEST_TMPDIR/extras/10-mine.sh"
  GAIA_EXTRA_STEPS_DIR=$BATS_TEST_TMPDIR/extras run bash "$REPO/bootstrap.sh" --list-steps
  assert_success
  assert_output --regexp 'custom:mine +custom +my step'
  [[ $output =~ caddy.*custom:mine.*audit-after ]]
}

@test "--version prints the version" {
  run bash "$REPO/bootstrap.sh" --version
  assert_success
  assert_output --regexp '^gaia [0-9]+\.[0-9]+\.[0-9]+$'
}

@test "--only runs just the given steps; the others show as skipped" {
  existing_admin
  gaia --only time,firewall
  assert_success
  assert_status time 'done'
  assert_status firewall 'done'
  assert_status ssh skipped
  assert_status docker skipped
}

@test "--skip accepts commas and can be repeated" {
  gaia --skip audit-before,audit-after --skip docker --dry-run
  assert_success
  assert_status audit-before skipped
  assert_status audit-after skipped
}

@test "unknown step in --only is refused before anything runs" {
  gaia --only nope
  assert_failure 2
  assert_output --partial 'unknown step: nope'
  refute_called 'apt-get'
}

@test "unknown option shows the usage and exits with 2" {
  gaia --bogus
  assert_failure 2
  assert_output --partial 'unknown option: --bogus'
  assert_output --partial 'usage:'
}

@test "a missing --config file is a clear error" {
  run bash "$REPO/bootstrap.sh" --config /nope/gaia.conf --yes
  assert_failure
  assert_output --partial 'configuration file not found'
}

@test "without a config file, the command line alone is enough" {
  run bash "$REPO/bootstrap.sh" --yes --dry-run --admin-user alice --ssh-key "$PUBKEY" --allow 80/tcp,443/tcp --no-audit
  assert_success
  assert_output --partial 'admin=alice'
  assert_output --partial 'firewall_allow="80/tcp 443/tcp"'
  assert_status audit-before skipped
}

@test "command line values override gaia.conf" {
  conf 'GAIA_SSH_PORT=2222'
  gaia --dry-run --ssh-port 2200 --only ssh
  assert_success
  assert_output --partial 'ssh_port=2200'
}

@test "without --yes and without a terminal, applying changes is refused" {
  run bash "$REPO/bootstrap.sh" --config "$CONF"
  assert_failure
  assert_output --partial 'no terminal to confirm'
}

@test "without --yes, --dry-run runs without asking" {
  run bash "$REPO/bootstrap.sh" --config "$CONF" --dry-run
  assert_success
}

@test "answering no at the confirmation cancels" {
  tty_answers none n
  run bash "$REPO/bootstrap.sh" --config "$CONF"
  assert_failure
  assert_output --partial 'cancelled by the user'
  refute_called 'apt-get'
}

@test "invalid value in the config is refused (SSH port)" {
  conf 'GAIA_SSH_PORT=70000'
  gaia --dry-run
  assert_failure
  assert_output --partial 'invalid value for GAIA_SSH_PORT'
}

@test "no administrator anywhere is refused before any change" {
  printf 'GAIA_ADMIN_SSH_KEYS="%s"\n' "$PUBKEY" >"$CONF"
  gaia
  assert_failure
  assert_output --partial 'no administrator account'
  refute_called 'apt-get'
}

@test "run through sudo: the sudo user becomes the administrator" {
  printf 'GAIA_ADMIN_SSH_KEYS="%s"\n' "$PUBKEY" >"$CONF"
  SUDO_USER=ubuntu gaia --dry-run --only preflight
  assert_success
  assert_output --partial 'using the user who ran sudo'
  assert_output --partial 'admin=ubuntu'
}
