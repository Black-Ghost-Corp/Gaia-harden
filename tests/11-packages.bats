#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# packages step: apt update (cached), full-upgrade when there are updates, base packages.

load test_helper

@test "fresh machine: update, full-upgrade and the missing base packages" {
  echo "Inst libc6 [2.39-0ubuntu8] (2.39-0ubuntu8.3 Ubuntu:24.04/noble-updates [amd64])" >"$STUB_STATE/updates"
  installed_packages ca-certificates
  gaia --only packages
  assert_success
  assert_called '^apt-get .*update$'
  assert_called '^apt-get .*full-upgrade$'
  assert_called '^apt-get .*install .*curl .*jq .*iproute2 .*ufw .*fail2ban .*unattended-upgrades'
  assert_called '^apt-get .*install .*systemd-timesyncd'
  assert_called '^apt-get .*install .*apparmor'
  refute_called '^apt-get .*install .*ca-certificates'
  refute_called '^apt-get .*install .*(htop|git)( |$)'
  assert_called '-o Dpkg::Options::=--force-confold'
  assert_status packages 'done'
}

@test "second run: recent lists, nothing to upgrade, nothing to install" {
  gaia --only packages
  assert_success
  clear_calls
  gaia --only packages
  assert_success
  assert_no_mutation
  assert_status packages ok
  assert_output --partial 'all base packages are already installed'
}

@test "GAIA_APT_FULL_UPGRADE=0 skips full-upgrade" {
  echo "Inst libc6 [1] (2 x)" >"$STUB_STATE/updates"
  conf "GAIA_APT_FULL_UPGRADE=0"
  gaia --only packages
  assert_success
  refute_called 'full-upgrade$'
}

@test "debian uses chrony and installs GAIA_EXTRA_PACKAGES" {
  os_release debian 12 bookworm
  conf 'GAIA_EXTRA_PACKAGES="tmux ncdu"'
  gaia --only packages
  assert_success
  assert_called '^apt-get .*install .*chrony'
  assert_called '^apt-get .*install .*tmux ncdu'
  refute_called 'systemd-timesyncd'
}

@test "GAIA_APPARMOR=0 does not install apparmor" {
  conf "GAIA_APPARMOR=0"
  gaia --only packages
  assert_success
  refute_called 'install .*apparmor'
}

@test "an apt-get failure shows up in the log with its code and the step fails" {
  force_failure apt-get 100
  echo "E: Unable to locate package something" >"$STUB_STATE/out/apt-get"
  gaia --only packages
  assert_failure
  assert_output --regexp 'error.*output: E: Unable to locate package'
  assert_output --regexp 'error.*command returned an error code=100'
  assert_status packages failed
}

@test "dry-run runs no apt-get that changes anything" {
  echo "Inst libc6 [1] (2 x)" >"$STUB_STATE/updates"
  gaia --dry-run --only packages
  assert_success
  assert_no_mutation
  assert_output --partial '[dry-run] would run: apt-get'
  assert_status packages 'would change'
}

@test "an invalid package name in GAIA_EXTRA_PACKAGES is refused" {
  conf 'GAIA_EXTRA_PACKAGES="tmux; rm -rf /"'
  gaia --only packages
  assert_failure
  assert_output --partial 'invalid value for GAIA_EXTRA_PACKAGES'
}
