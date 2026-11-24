#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# hostname step: optional; hostnamectl, /etc/hosts and cloud-init.

load test_helper

@test "without GAIA_HOSTNAME the step is skipped" {
  gaia --only hostname
  assert_success
  assert_status hostname skipped
  refute_called 'hostnamectl'
}

@test "sets the host name, adds 127.0.1.1 to /etc/hosts and keeps the other lines" {
  gaia --only hostname --hostname web-01.example.com
  assert_success
  assert_called '^hostnamectl set-hostname web-01$'
  run cat "$FAKE_ROOT/etc/hosts"
  assert_line '127.0.0.1 localhost'
  assert_line '::1 localhost ip6-localhost ip6-loopback'
  assert_line '127.0.1.1 web-01.example.com web-01'
}

@test "replaces an existing 127.0.1.1 line instead of adding another" {
  printf '127.0.0.1 localhost\n127.0.1.1 vps-12345\n' >"$FAKE_ROOT/etc/hosts"
  gaia --only hostname --hostname web-01
  assert_success
  run grep -c '^127.0.1.1' "$FAKE_ROOT/etc/hosts"
  assert_output 1
  run grep '^127.0.1.1' "$FAKE_ROOT/etc/hosts"
  assert_output '127.0.1.1 web-01'
}

@test "with cloud-init, the name is preserved across reboots" {
  mkdir -p "$FAKE_ROOT/etc/cloud/cloud.cfg.d"
  gaia --only hostname --hostname web-01
  assert_success
  run cat "$FAKE_ROOT/etc/cloud/cloud.cfg.d/99-gaia-hostname.cfg"
  assert_output --partial 'preserve_hostname: true'
}

@test "second run changes nothing" {
  gaia --only hostname --hostname web-01
  assert_success
  clear_calls
  gaia --only hostname --hostname web-01
  assert_success
  assert_no_mutation
  assert_status hostname ok
}

@test "an invalid host name is refused" {
  gaia --only hostname --hostname 'Web_01!'
  assert_failure
  assert_output --partial 'invalid value for GAIA_HOSTNAME'
}
