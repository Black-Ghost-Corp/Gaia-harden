#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# auto-updates step: unattended-upgrades with the security origin only.

load test_helper

UU=/etc/apt/apt.conf.d/52gaia-unattended-upgrades

@test "ubuntu: security origin only, previous origins cleared, reboot off" {
  gaia --only auto-updates
  assert_success
  run cat "$FAKE_ROOT/etc/apt/apt.conf.d/20auto-upgrades"
  assert_line 'APT::Periodic::Unattended-Upgrade "1";'
  run cat "$FAKE_ROOT$UU"
  assert_line '#clear Unattended-Upgrade::Allowed-Origins;'
  assert_line '#clear Unattended-Upgrade::Origins-Pattern;'
  assert_output --partial 'origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu'
  refute_output --regexp 'archive=\$\{distro_codename\}-updates'
  assert_line 'Unattended-Upgrade::Automatic-Reboot "false";'
}

@test "debian: Debian-Security origin" {
  os_release debian 12 bookworm
  gaia --only auto-updates
  assert_success
  run cat "$FAKE_ROOT$UU"
  assert_output --partial 'origin=Debian,codename=${distro_codename}-security,label=Debian-Security'
}

@test "configurable automatic reboot with a time" {
  conf GAIA_AUTO_REBOOT=1 GAIA_AUTO_REBOOT_TIME=03:30
  gaia --only auto-updates
  assert_success
  run cat "$FAKE_ROOT$UU"
  assert_line 'Unattended-Upgrade::Automatic-Reboot "true";'
  assert_line 'Unattended-Upgrade::Automatic-Reboot-Time "03:30";'
}

@test "second run changes nothing" {
  gaia --only auto-updates
  assert_success
  clear_calls
  gaia --only auto-updates
  assert_success
  assert_no_mutation
  assert_status auto-updates ok
}
