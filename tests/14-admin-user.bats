#!/usr/bin/env bats
# admin-user step: creates the user, sudo group, installs keys (literal, GitHub or imported) and never
# removes existing ones.

load test_helper

ak() { cat "$FAKE_ROOT/home/admin/.ssh/authorized_keys"; }

@test "creates the user in the sudo group and installs the key with the right modes" {
  gaia --only admin-user
  assert_success
  assert_called '^useradd .*--groups sudo.* admin$'
  assert_output --regexp 'key added type=ssh-ed25519 comment=admin@laptop'
  run ak
  assert_output "$PUBKEY"
  run env PATH="$STUB_REAL_PATH" stat -c %a "$FAKE_ROOT/home/admin/.ssh" "$FAKE_ROOT/home/admin/.ssh/authorized_keys"
  assert_line --index 0 700
  assert_line --index 1 600
  assert_called "^chown admin:admin $FAKE_ROOT/home/admin/.ssh$"
  assert_called "^chown admin:admin $FAKE_ROOT/home/admin/.ssh/authorized_keys$"
}

@test "second run changes nothing" {
  gaia --only admin-user
  assert_success
  clear_calls
  gaia --only admin-user
  assert_success
  assert_no_mutation
  assert_status admin-user ok
}

@test "never removes existing keys; only appends new ones" {
  existing_admin
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldKeyThatMustStayHere999 old@machine" >>"$FAKE_ROOT/home/admin/.ssh/authorized_keys"
  cat >>"$CONF" <<EOF
GAIA_ADMIN_SSH_KEYS="$PUBKEY
$PUBKEY2"
EOF
  gaia --only admin-user
  assert_success
  assert_output --regexp 'key already present.*comment=admin@laptop'
  run ak
  assert_line --index 0 "$PUBKEY"
  assert_line --index 1 --partial 'old@machine'
  assert_line --index 2 "$PUBKEY2"
  refute_called '^useradd'
}

@test "an existing user outside sudo is added to the group" {
  echo "admin admin" >"$STUB_STATE/users/admin"
  gaia --only admin-user
  assert_success
  assert_called '^usermod -aG sudo admin$'
  refute_called '^useradd'
}

@test "an invalid key is refused and nothing is installed" {
  conf 'GAIA_ADMIN_SSH_KEYS="this is not a key"'
  gaia --only admin-user
  assert_failure
  assert_output --partial 'invalid public key'
  [[ ! -f $FAKE_ROOT/home/admin/.ssh/authorized_keys ]]
}

@test "--ssh-key on the command line works without any key in the config" {
  write_conf
  sed -i '/GAIA_ADMIN_SSH_KEYS/d' "$CONF"
  gaia --only admin-user --ssh-key "$PUBKEY2"
  assert_success
  run ak
  assert_output "$PUBKEY2"
}

@test "--github-keys imports the user's public keys from GitHub" {
  sed -i '/GAIA_ADMIN_SSH_KEYS/d' "$CONF"
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGitHubKeyNumberOne0123456789abcdef' >"$STUB_STATE/github_keys/octocat"
  gaia --only admin-user --github-keys octocat
  assert_success
  assert_called '^curl .*https://github.com/octocat.keys'
  run ak
  assert_output 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGitHubKeyNumberOne0123456789abcdef github:octocat'
}

@test "a GitHub user without keys is an error" {
  gaia --only admin-user --github-keys nobody-here
  assert_failure
  assert_output --partial "GitHub user 'nobody-here'"
}

@test "without configured keys, imports root's keys and drops the cloud 'Please login as' options" {
  sed -i '/GAIA_ADMIN_SSH_KEYS/d' "$CONF"
  printf '%s\n' "no-port-forwarding,command=\"echo 'Please login as the user \\\"ubuntu\\\" rather than root.';sleep 10\" $PUBKEY" \
    >"$FAKE_ROOT/root/.ssh/authorized_keys"
  gaia --only admin-user
  assert_success
  run ak
  assert_output "$PUBKEY"
}

@test "with configured keys, root's keys are not imported (GAIA_ADMIN_IMPORT_KEYS=auto)" {
  printf '%s\n' "$PUBKEY2" >"$FAKE_ROOT/root/.ssh/authorized_keys"
  gaia --only admin-user
  assert_success
  run ak
  assert_output "$PUBKEY"
}

@test "no key from any source is refused (key-only SSH would lock you out)" {
  sed -i '/GAIA_ADMIN_SSH_KEYS/d' "$CONF"
  gaia --only admin-user
  assert_failure
  assert_output --partial 'no public key for the administrator'
}

@test "GAIA_ADMIN_SUDO_NOPASSWD=0 and a locked password: warns that sudo will ask for one" {
  conf GAIA_ADMIN_SUDO_NOPASSWD=0
  gaia --only admin-user
  assert_success
  assert_output --regexp 'warn.*no password.*passwd admin'
  [[ ! -e $FAKE_ROOT/etc/sudoers.d/90-gaia-admin ]]
}

@test "default: passwordless sudo in sudoers.d, checked with visudo, mode 440" {
  gaia --only admin-user
  assert_success
  run cat "$FAKE_ROOT/etc/sudoers.d/90-gaia-admin"
  assert_output --partial 'admin ALL=(ALL) NOPASSWD:ALL'
  run env PATH="$STUB_REAL_PATH" stat -c %a "$FAKE_ROOT/etc/sudoers.d/90-gaia-admin"
  assert_output 440
  assert_called '^visudo -cf '
}

@test "dry-run creates neither the user nor files" {
  gaia --dry-run --only admin-user
  assert_success
  assert_no_mutation
  [[ ! -e $FAKE_ROOT/home/admin/.ssh ]]
  assert_output --partial '[dry-run] would run: useradd'
}
