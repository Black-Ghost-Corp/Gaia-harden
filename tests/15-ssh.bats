#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# ssh step: hardening drop-in (modern crypto, AllowUsers), with lock-out protection.

load test_helper

DROPIN=/etc/ssh/sshd_config.d/00-gaia.conf

@test "with an admin key: writes the drop-in, checks with sshd -t and reloads (never restarts)" {
  existing_admin
  touch "$STUB_STATE/units/ssh.active"
  gaia --only ssh
  assert_success
  assert_status ssh 'done'
  run cat "$FAKE_ROOT$DROPIN"
  assert_line 'PermitRootLogin no'
  assert_line 'PasswordAuthentication no'
  assert_line 'KbdInteractiveAuthentication no'
  assert_line 'Port 22'
  assert_line 'MaxAuthTries 3'
  assert_line 'LoginGraceTime 30'
  assert_line 'AllowTcpForwarding local'
  assert_line 'AllowAgentForwarding no'
  assert_line 'AllowUsers admin'
  assert_called '^sshd -t$'
  assert_called '^systemctl reload ssh.service$'
  refute_called '^systemctl restart ssh'
  [[ $(call_line '^sshd -t') -lt $(call_line '^systemctl reload') ]]
}

@test "modern crypto: only algorithms the installed OpenSSH supports, strongest first" {
  existing_admin
  gaia --only ssh
  assert_success
  run cat "$FAKE_ROOT$DROPIN"
  # The fake OpenSSH (9.6) has no ML-KEM: it must not be written, or sshd would refuse the file.
  assert_line 'KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group18-sha512,diffie-hellman-group16-sha512'
  assert_line 'Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr'
  assert_line 'MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com'
  refute_output --partial 'mlkem'
}

@test "GAIA_SSH_MODERN_CRYPTO=0 keeps OpenSSH's default algorithms" {
  existing_admin
  conf GAIA_SSH_MODERN_CRYPTO=0
  gaia --only ssh
  assert_success
  run grep -E '^(KexAlgorithms|Ciphers|MACs) ' "$FAKE_ROOT$DROPIN"
  assert_failure
}

@test "AllowUsers lists the administrator plus GAIA_SSH_ALLOW_USERS; empty removes the line" {
  existing_admin
  conf 'GAIA_SSH_ALLOW_USERS="@admin deploy"'
  gaia --only ssh
  assert_success
  run grep '^AllowUsers' "$FAKE_ROOT$DROPIN"
  assert_output 'AllowUsers admin deploy'
  conf 'GAIA_SSH_ALLOW_USERS=""'
  gaia --only ssh
  assert_success
  run grep -c '^AllowUsers' "$FAKE_ROOT$DROPIN"
  assert_output 0
}

@test "warns about other users with SSH keys that AllowUsers would lock out" {
  existing_admin
  mkdir -p "$FAKE_ROOT/home/ubuntu/.ssh"
  printf '%s\n' "$PUBKEY2" >"$FAKE_ROOT/home/ubuntu/.ssh/authorized_keys"
  gaia --only ssh
  assert_success
  assert_output --regexp 'warn.*not in AllowUsers.*user=ubuntu'
}

@test "LOCK-OUT: admin without any valid key -> refuses and leaves password auth alone" {
  echo "admin sudo" >"$STUB_STATE/users/admin"
  mkdir -p "$FAKE_ROOT/home/admin/.ssh"
  echo "# empty" >"$FAKE_ROOT/home/admin/.ssh/authorized_keys"
  gaia --only ssh
  assert_failure
  assert_output --partial 'REFUSED'
  [[ ! -e $FAKE_ROOT$DROPIN ]]
  refute_called '^systemctl (reload|restart)'
  assert_status ssh failed
}

@test "LOCK-OUT: missing admin -> refuses" {
  gaia --only ssh
  assert_failure
  assert_output --partial 'REFUSED'
  [[ ! -e $FAKE_ROOT$DROPIN ]]
}

@test "LOCK-OUT: sshd -t fails -> removes the drop-in, does not reload and the step fails" {
  existing_admin
  touch "$STUB_STATE/units/ssh.active"
  force_failure sshd_-t 255
  echo "/etc/ssh/sshd_config.d/00-gaia.conf line 3: Bad configuration option" >"$STUB_STATE/out/sshd_-t"
  gaia --only ssh
  assert_failure
  [[ ! -e $FAKE_ROOT$DROPIN ]]
  refute_called '^systemctl (reload|restart)'
  assert_output --regexp 'error.*sshd -t rejected'
  assert_output --partial 'Bad configuration option'
  assert_status ssh failed
}

@test "LOCK-OUT: sshd -t fails on a change -> restores the previous drop-in" {
  existing_admin
  printf 'Port 22\n' >"$FAKE_ROOT$DROPIN"
  force_failure sshd_-t 255
  conf GAIA_SSH_PORT=2222
  gaia --only ssh
  assert_failure
  run cat "$FAKE_ROOT$DROPIN"
  assert_output 'Port 22'
}

@test "second run changes nothing" {
  existing_admin
  touch "$STUB_STATE/units/ssh.active"
  gaia --only ssh
  assert_success
  clear_calls
  gaia --only ssh
  assert_success
  assert_no_mutation
  assert_status ssh ok
}

@test "another drop-in that wins over ours is detected (effective configuration differs)" {
  existing_admin
  printf 'PasswordAuthentication yes\n' >"$FAKE_ROOT/etc/ssh/sshd_config.d/00-aaa-cloud.conf"
  gaia --only ssh
  assert_failure
  assert_output --regexp 'error.*effective sshd configuration.*option=passwordauthentication'
  [[ ! -e $FAKE_ROOT$DROPIN ]]
}

@test "sshd_config without the sshd_config.d Include is refused" {
  existing_admin
  printf 'Port 22\n' >"$FAKE_ROOT/etc/ssh/sshd_config"
  gaia --only ssh
  assert_failure
  assert_output --partial 'Include'
}

@test "new port with the ssh socket (Ubuntu 24.04+): daemon-reload and ssh.socket restart" {
  existing_admin
  touch "$STUB_STATE/units/ssh.socket.enabled"
  conf GAIA_SSH_PORT=2222
  gaia --only ssh
  assert_success
  assert_called '^systemctl daemon-reload$'
  assert_called '^systemctl restart ssh.socket$'
  assert_output --regexp 'warn.*SSH port changed'
}

@test "new port with ufw active opens (rate-limited) the new port BEFORE applying" {
  existing_admin
  touch "$STUB_STATE/units/ssh.active" "$STUB_STATE/ufw/active"
  conf GAIA_SSH_PORT=2222
  gaia --only ssh
  assert_success
  assert_called '^ufw limit 2222/tcp$'
  [[ $(call_line '^ufw limit 2222/tcp') -lt $(call_line '^sshd -t') ]]
}

@test "dry-run: with the key only in the config, shows the diff and writes nothing" {
  gaia --dry-run --only ssh
  assert_success
  assert_no_mutation
  [[ ! -e $FAKE_ROOT$DROPIN ]]
  assert_output --partial "[dry-run] would create file file=$DROPIN"
  assert_output --partial '[dry-run] diff: +PasswordAuthentication no'
}

@test "dry-run without openssh-server installed yet: warns instead of failing" {
  rm -f "$FAKE_ROOT/etc/ssh/sshd_config"
  gaia --dry-run --only ssh
  assert_success
  assert_output --regexp 'warn.*openssh-server'
  assert_output --partial '[dry-run] would create file'
}
