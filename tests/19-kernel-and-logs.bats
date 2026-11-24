#!/usr/bin/env bats
# sysctl, journald, apparmor and swap steps.

load test_helper

SYSCTL=/etc/sysctl.d/90-gaia-hardening.conf

@test "sysctl: writes the hardening file and applies it, ignoring unknown keys" {
  gaia --only sysctl
  assert_success
  run cat "$FAKE_ROOT$SYSCTL"
  assert_line 'net.ipv4.conf.all.rp_filter = 1'
  assert_line 'net.ipv4.conf.all.accept_redirects = 0'
  assert_line 'net.ipv4.tcp_syncookies = 1'
  assert_line 'kernel.kptr_restrict = 2'
  assert_line 'kernel.dmesg_restrict = 1'
  refute_output --partial 'ip_forward'
  assert_called "^sysctl -e -q -p $FAKE_ROOT$SYSCTL$"
}

@test "sysctl: GAIA_SYSCTL_EXTRA is appended; second run changes nothing" {
  conf 'GAIA_SYSCTL_EXTRA="vm.max_map_count=262144"'
  gaia --only sysctl
  assert_success
  run grep max_map_count "$FAKE_ROOT$SYSCTL"
  assert_output 'vm.max_map_count = 262144'
  clear_calls
  gaia --only sysctl
  assert_no_mutation
  assert_status sysctl ok
}

@test "sysctl: an invalid GAIA_SYSCTL_EXTRA is refused" {
  conf 'GAIA_SYSCTL_EXTRA="vm.max_map_count 262144"'
  gaia --only sysctl
  assert_failure
  assert_output --partial 'invalid value in GAIA_SYSCTL_EXTRA'
}

@test "sysctl, apparmor and swap are skipped inside a container" {
  export GAIA_CONTAINER=1
  gaia --only sysctl,apparmor,swap --swap 1G
  assert_success
  assert_status sysctl skipped
  assert_status apparmor skipped
  assert_status swap skipped
  [[ ! -e $FAKE_ROOT$SYSCTL ]]
}

@test "journald: persistent, compressed, capped; restarts journald only on change" {
  conf GAIA_JOURNALD_MAX_USE=1G
  gaia --only journald
  assert_success
  run cat "$FAKE_ROOT/etc/systemd/journald.conf.d/90-gaia.conf"
  assert_line 'Storage=persistent'
  assert_line 'SystemMaxUse=1G'
  assert_called '^systemctl restart systemd-journald$'
  clear_calls
  gaia --only journald
  assert_no_mutation
}

@test "apparmor: enables the service and reports the profiles" {
  gaia --only apparmor
  assert_success
  assert_called '^systemctl enable --now apparmor$'
  assert_output --partial 'AppArmor active profiles=3 enforce=2'
}

@test "apparmor: disabled in the kernel -> warns and skips" {
  echo N >"$FAKE_ROOT/sys/module/apparmor/parameters/enabled"
  gaia --only apparmor
  assert_success
  assert_output --regexp 'warn.*AppArmor is disabled in the kernel'
  assert_status apparmor skipped
}

@test "swap: skipped without GAIA_SWAP_SIZE" {
  gaia --only swap
  assert_success
  assert_status swap skipped
}

@test "swap: creates, activates and persists the swap file, with low swappiness" {
  gaia --only swap --swap 2G
  assert_success
  assert_called "^fallocate -l 2G $FAKE_ROOT/swapfile$"
  assert_called "^mkswap $FAKE_ROOT/swapfile$"
  assert_called "^swapon $FAKE_ROOT/swapfile$"
  run cat "$FAKE_ROOT/etc/fstab"
  assert_output '/swapfile none swap sw 0 0'
  run cat "$FAKE_ROOT/etc/sysctl.d/91-gaia-swap.conf"
  assert_line 'vm.swappiness = 10'
  clear_calls
  gaia --only swap --swap 2G
  assert_success
  assert_no_mutation
  assert_status swap ok
}

@test "swap: a system that already has swap is left alone" {
  echo /dev/sda3 >"$STUB_STATE/swaps"
  gaia --only swap --swap 2G
  assert_success
  assert_output --partial 'already has swap'
  refute_called '^(fallocate|mkswap)'
}
