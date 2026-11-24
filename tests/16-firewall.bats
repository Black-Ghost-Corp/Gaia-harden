#!/usr/bin/env bats
# firewall step: ufw deny/allow defaults, SSH (rate-limited) before enabling, extra rules.

load test_helper

@test "deny/allow defaults, SSH rate-limited first, then the extra rules, and only then enable" {
  gaia --only firewall
  assert_success
  assert_called '^ufw default deny incoming$'
  assert_output --partial 'outbound already allowed by default'
  assert_called '^ufw limit 22/tcp$'
  assert_called '^ufw allow 80/tcp$'
  assert_called '^ufw allow 443/tcp$'
  assert_called '^ufw --force enable$'
  [[ $(call_line '^ufw limit 22/tcp') -lt $(call_line '^ufw allow 80/tcp') ]]
  [[ $(call_line '^ufw allow 443/tcp') -lt $(call_line '^ufw --force enable') ]]
}

@test "GAIA_SSH_RATE_LIMIT=0 uses a plain allow rule" {
  conf GAIA_SSH_RATE_LIMIT=0
  gaia --only firewall
  assert_success
  assert_called '^ufw allow 22/tcp$'
  refute_called '^ufw limit'
}

@test "uses the configured SSH port" {
  gaia --only firewall --ssh-port 2222
  assert_success
  assert_called '^ufw limit 2222/tcp$'
  refute_called '[^0-9]22/tcp$'
}

@test "second run changes nothing" {
  gaia --only firewall
  assert_success
  clear_calls
  gaia --only firewall
  assert_success
  assert_no_mutation
  assert_status firewall ok
}

@test "a new SSH port keeps the old rule and warns to remove it later" {
  gaia --only firewall
  conf GAIA_SSH_PORT=2222
  gaia --only firewall
  assert_success
  assert_output --regexp 'warn.*old 22/tcp rule'
}

@test "an invalid rule in GAIA_FIREWALL_ALLOW / --allow is refused before anything" {
  gaia --only firewall --allow 80/tcp,abc
  assert_failure
  assert_output --partial "invalid firewall rule: 'abc'"
  refute_called '^ufw '
}

@test "a port range needs a protocol" {
  gaia --only firewall --allow 60000:61000
  assert_failure
  assert_output --partial 'a port range needs a protocol'
}

@test "dry-run calls no ufw command that changes anything" {
  gaia --dry-run --only firewall
  assert_success
  assert_no_mutation
  assert_output --partial '[dry-run] would run: ufw --force enable'
}
