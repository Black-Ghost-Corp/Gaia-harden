#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# System detection: accepts Ubuntu 22.04/24.04/26.04 and Debian 12/13 on amd64/arm64; refuses the rest.

load test_helper

@test "accepts ubuntu 24.04 amd64" {
  gaia --only preflight
  assert_success
  assert_output --regexp 'system detected.*id=ubuntu version=24.04 codename=noble arch=amd64'
}

@test "accepts ubuntu 26.04 (resolute)" {
  os_release ubuntu 26.04 resolute
  gaia --only preflight
  assert_success
  assert_output --regexp 'system detected.*id=ubuntu version=26.04 codename=resolute'
}

@test "refuses ubuntu 25.10 (not LTS)" {
  os_release ubuntu 25.10 questing
  gaia --only preflight
  assert_failure
  assert_output --partial 'unsupported system'
}

@test "accepts ubuntu 22.04" {
  os_release ubuntu 22.04 jammy
  gaia --only preflight
  assert_success
}

@test "accepts debian 12 arm64" {
  os_release debian 12 bookworm
  export STUB_ARCH=arm64
  gaia --only preflight
  assert_success
  assert_output --partial 'arch=arm64'
}

@test "accepts debian 13" {
  os_release debian 13 trixie
  gaia --only preflight
  assert_success
}

@test "refuses ubuntu 20.04 with a clear message" {
  os_release ubuntu 20.04 focal
  gaia --only preflight
  assert_failure
  assert_output --partial 'unsupported system'
  assert_output --partial 'Ubuntu 22.04/24.04/26.04, Debian 12/13'
}

@test "refuses another distribution (rocky)" {
  os_release rocky 9.3 blue
  gaia --only preflight
  assert_failure
  assert_output --partial 'unsupported system'
}

@test "refuses the armhf architecture" {
  export STUB_ARCH=armhf
  gaia --only preflight
  assert_failure
  assert_output --partial 'unsupported architecture: armhf'
}

@test "the refusal also applies to --dry-run" {
  os_release debian 11 bullseye
  gaia --dry-run --only preflight
  assert_failure
  assert_output --partial 'unsupported system'
}

@test "requires root" {
  export STUB_EUID=1000
  gaia --only preflight
  assert_failure
  assert_output --partial 'must run as root'
}

@test "missing /etc/os-release is an error" {
  rm "$FAKE_ROOT/etc/os-release"
  gaia --only preflight
  assert_failure
  assert_output --partial '/etc/os-release'
}
