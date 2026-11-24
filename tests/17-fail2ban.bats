#!/usr/bin/env bats
# fail2ban step: sshd jail on the configured port, checked with fail2ban-client -t.

load test_helper

JAIL=/etc/fail2ban/jail.d/gaia.local

@test "creates the sshd jail with the configured port, checks it and starts the service" {
  conf GAIA_SSH_PORT=2222 GAIA_FAIL2BAN_MAXRETRY=3
  gaia --only fail2ban
  assert_success
  run cat "$FAKE_ROOT$JAIL"
  assert_line 'port = 2222'
  assert_line 'maxretry = 3'
  assert_line 'backend = systemd'
  assert_called '^fail2ban-client -t$'
  assert_called '^systemctl enable --now fail2ban$'
}

@test "config change with the service running: reloads" {
  active_unit fail2ban
  gaia --only fail2ban
  assert_success
  assert_called '^systemctl reload fail2ban$'
}

@test "second run changes nothing" {
  gaia --only fail2ban
  assert_success
  clear_calls
  gaia --only fail2ban
  assert_success
  assert_no_mutation
  assert_status fail2ban ok
}

@test "config rejected by fail2ban-client -t: rolled back and the step fails" {
  force_failure fail2ban-client 255
  echo "ERROR: bad jail" >"$STUB_STATE/out/fail2ban-client"
  gaia --only fail2ban
  assert_failure
  assert_output --partial 'bad jail'
  [[ ! -e $FAKE_ROOT$JAIL ]]
  refute_called '^systemctl (enable|reload)'
}
