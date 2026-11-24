#!/usr/bin/env bats
# time step: time zone and NTP.

load test_helper

@test "sets the default time zone (UTC) and turns NTP on" {
  echo America/Sao_Paulo >"$STUB_STATE/timezone"
  gaia --only time
  assert_success
  assert_called '^timedatectl set-timezone UTC$'
  assert_called '^timedatectl set-ntp true$'
  assert_status time 'done'
}

@test "GAIA_TIMEZONE / --timezone choose another zone" {
  gaia --only time --timezone America/Sao_Paulo
  assert_success
  assert_called '^timedatectl set-timezone America/Sao_Paulo$'
}

@test "second run changes nothing and says it was already ok" {
  conf GAIA_TIMEZONE=America/Sao_Paulo
  gaia --only time
  assert_success
  clear_calls
  gaia --only time
  assert_success
  assert_no_mutation
  assert_status time ok
  assert_output --partial 'time zone already correct'
}

@test "an unknown time zone is refused" {
  conf "GAIA_TIMEZONE=Mars/Olympus"
  gaia --only time
  assert_failure
  assert_output --partial 'unknown time zone'
  refute_called '^timedatectl set-'
}

@test "debian uses chrony (the distribution's NTP package) through systemctl" {
  os_release debian 12 bookworm
  gaia --only time
  assert_success
  assert_called '^systemctl enable --now chrony'
  refute_called '^timedatectl set-ntp'
}

@test "dry-run changes neither the time zone nor NTP" {
  conf GAIA_TIMEZONE=America/Sao_Paulo
  gaia --dry-run --only time
  assert_success
  assert_no_mutation
  assert_output --regexp '\[dry-run\] would run: timedatectl set-timezone America/Sao_Paulo'
}

@test "dry-run without tzdata yet: warns instead of failing (the packages step installs it)" {
  rm -rf "$FAKE_ROOT/usr/share/zoneinfo"
  gaia --dry-run --only time
  assert_success
  assert_output --regexp 'warn.*tzdata'
  gaia --only time
  assert_failure
}

# The machine running the tests may have a real timedatectl; then absence cannot be simulated.
no_timedatectl() {
  rm -f "$SHIMS/timedatectl"
  if PATH=$STUB_REAL_PATH command -v timedatectl >/dev/null; then skip "this machine has a real timedatectl"; fi
}

@test "dry-run without timedatectl (no systemd): warns instead of breaking with 127" {
  no_timedatectl
  gaia --dry-run --only time
  assert_success
  assert_output --regexp 'warn.*timedatectl'
  refute_output --partial 'code=127'
}

@test "real run without timedatectl: fails with a clear message (systemd required)" {
  no_timedatectl
  gaia --only time
  assert_failure
  assert_output --regexp 'error.*timedatectl.*systemd'
  refute_output --partial 'code=127'
}

@test "ubuntu 26.04 uses chrony (the default since 25.10)" {
  os_release ubuntu 26.04 resolute
  gaia --only time
  assert_success
  assert_called '^systemctl enable --now chrony'
  refute_called '^timedatectl set-ntp'
}
