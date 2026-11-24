# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# Shared test utilities: fake root (GAIA_ROOT), shims for system commands and assertions.

bats_load_library bats-support
bats_load_library bats-assert

REPO=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
FAKE=$REPO/tests/fakes/fake-system.bash

# System commands replaced by shims. Everything that changes the machine goes through here.
FAKE_COMMANDS=(id getent useradd usermod passwd chown stat dpkg-query dpkg apt-get systemctl
  timedatectl hostnamectl sshd ssh ufw fail2ban-client curl gpg df ss sysctl swapon fallocate mkswap
  postconf update-exim4.conf lynis docker visudo caddy)

PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGaiaTestFakePublicKey0123456789abcdefghijk admin@laptop'
PUBKEY2='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDSecondFakeKey0123456789 other@desktop'

setup() {
  FAKE_ROOT=$BATS_TEST_TMPDIR/root
  STUB_STATE=$BATS_TEST_TMPDIR/state
  SHIMS=$BATS_TEST_TMPDIR/shims
  CONF=$BATS_TEST_TMPDIR/gaia.conf
  mkdir -p "$FAKE_ROOT" "$STUB_STATE"/{users,units,ufw,rc,out,github_keys} "$SHIMS"
  : >"$STUB_STATE/calls.log"
  echo sudo >"$STUB_STATE/groups"
  : >"$STUB_STATE/packages"
  local c
  for c in "${FAKE_COMMANDS[@]}"; do
    printf '#!/usr/bin/env bash\nexec bash "%s" %s "$@"\n' "$FAKE" "$c" >"$SHIMS/$c"
    chmod +x "$SHIMS/$c"
  done
  export STUB_REAL_PATH=$PATH
  export PATH="$SHIMS:$PATH"
  export GAIA_ROOT=$FAKE_ROOT STUB_STATE
  # Deterministic environment: not a container, no terminal, not run through sudo.
  export GAIA_CONTAINER=0 GAIA_TTY_DEVICE=$BATS_TEST_TMPDIR/no-tty
  unset GAIA_DEBUG SUDO_USER GAIA_MODULES
  seed_root
  write_conf
  # Optional hook: a .bats file may define setup_extra() for what only it needs.
  if declare -F setup_extra >/dev/null; then setup_extra; fi
}

# A "freshly installed" machine: Ubuntu 24.04, systemd, default sshd_config with Include.
seed_root() {
  mkdir -p "$FAKE_ROOT"/{etc/ssh/sshd_config.d,etc/default,etc/apt/sources.list.d,etc/apt/apt.conf.d,etc/ufw}
  mkdir -p "$FAKE_ROOT"/{run/systemd/system,var/log,var/lib,usr/share/zoneinfo/America,home,etc/sudoers.d,root/.ssh}
  mkdir -p "$FAKE_ROOT"/sys/module/apparmor/parameters "$FAKE_ROOT"/sys/kernel/security/apparmor
  os_release ubuntu 24.04 noble
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n\nKbdInteractiveAuthentication no\nUsePAM yes\n' \
    >"$FAKE_ROOT/etc/ssh/sshd_config"
  printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="ACCEPT"\nDEFAULT_OUTPUT_POLICY="ACCEPT"\n' >"$FAKE_ROOT/etc/default/ufw"
  printf '*filter\n:ufw-after-input - [0:0]\nCOMMIT\n' >"$FAKE_ROOT/etc/ufw/after.rules"
  printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n' >"$FAKE_ROOT/etc/hosts"
  echo "vps-12345" >"$FAKE_ROOT/etc/hostname"
  echo Y >"$FAKE_ROOT/sys/module/apparmor/parameters/enabled"
  printf '/usr/bin/man (enforce)\n/usr/sbin/chronyd (enforce)\nlsb_release (complain)\n' \
    >"$FAKE_ROOT/sys/kernel/security/apparmor/profiles"
  cat >"$FAKE_ROOT/etc/apt/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates
Components: main restricted universe multiverse

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
EOF
  echo "TZif-fake" >"$FAKE_ROOT/usr/share/zoneinfo/UTC"
  echo "TZif-fake" >"$FAKE_ROOT/usr/share/zoneinfo/America/Sao_Paulo"
}

os_release() {
  local id=$1 version=$2 codename=$3
  cat >"$FAKE_ROOT/etc/os-release" <<EOF
PRETTY_NAME="$id $version ($codename)"
NAME="$id"
VERSION_ID="$version"
VERSION_CODENAME=$codename
ID=$id
EOF
}

write_conf() {
  cat >"$CONF" <<EOF
GAIA_ADMIN_USER=admin
GAIA_ADMIN_SSH_KEYS="$PUBKEY"
GAIA_FIREWALL_ALLOW="80/tcp 443/tcp"
EOF
}

conf() { printf '%s\n' "$@" >>"$CONF"; }

gaia() {
  run bash "$REPO/bootstrap.sh" --config "$CONF" --yes "$@"
}

clear_calls() { : >"$STUB_STATE/calls.log"; }
calls() { cat "$STUB_STATE/calls.log"; }

# Calls that only read state. Anything else counts as a change.
READ_ONLY='^(id( |$)|getent |stat |dpkg-query |dpkg --print-architecture|apt-get( [^ ]+)* -s( |$)|systemctl (--quiet )?(is-active|is-enabled|show|status)|timedatectl show|sshd -[tT]|ssh -Q|ufw (status|show)|fail2ban-client (-t|--test)|curl |gpg .*--show-keys|df |ss |swapon --show|postconf -h|passwd -S|visudo -c|lynis audit |docker run --rm hello-world)'
mutating_calls() { grep -Ev "$READ_ONLY" "$STUB_STATE/calls.log" || true; }

assert_no_mutation() {
  local m
  m=$(mutating_calls)
  if [[ -n $m ]]; then
    echo "calls that change state (expected: none):"
    echo "$m"
    return 1
  fi
}

assert_called() {
  grep -Eq -- "$1" "$STUB_STATE/calls.log" || {
    echo "expected a call matching: $1"
    echo "--- calls ---"
    calls
    return 1
  }
}

refute_called() {
  if grep -Eq -- "$1" "$STUB_STATE/calls.log"; then
    echo "did not expect a call matching: $1"
    echo "--- calls ---"
    calls
    return 1
  fi
}

# Line number of the first call matching the pattern.
call_line() { grep -nE -- "$1" "$STUB_STATE/calls.log" | head -n1 | cut -d: -f1; }

# Status of a step in the final summary: "| name | status |".
assert_status() {
  local step=$1 status=$2
  assert_output --regexp "\\| ${step} +\\| ${status} +\\|"
}

# Ready state for the steps that depend on the administrator.
existing_admin() {
  echo "admin sudo" >"$STUB_STATE/users/admin"
  echo P >"$STUB_STATE/users/admin.password"
  mkdir -p "$FAKE_ROOT/home/admin/.ssh"
  printf '%s\n' "$PUBKEY" >"$FAKE_ROOT/home/admin/.ssh/authorized_keys"
  chmod 700 "$FAKE_ROOT/home/admin/.ssh"
  chmod 600 "$FAKE_ROOT/home/admin/.ssh/authorized_keys"
  printf '%s\t%s\n' "/home/admin/.ssh" "admin:admin" "/home/admin/.ssh/authorized_keys" "admin:admin" |
    sed "s#^#$FAKE_ROOT#" >>"$STUB_STATE/owners"
}

installed_packages() { printf '%s\n' "$@" >>"$STUB_STATE/packages"; }
force_failure() { echo "${2:-1}" >"$STUB_STATE/rc/$1"; }
active_unit() { touch "$STUB_STATE/units/$1.active" "$STUB_STATE/units/$1.enabled"; }

# Answers for the interactive questions (one line per question), read as if typed in a terminal.
tty_answers() {
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/tty"
  export GAIA_TTY_DEVICE=$BATS_TEST_TMPDIR/tty
}

# Snapshot of the fake root (proves that a dry-run writes nothing but its log).
# Directories are listed without size and date: the log and the lock (outside the snapshot) change
# the date of /var/log and /run when they are created. A new or deleted file still shows up.
root_snapshot() {
  (cd "$FAKE_ROOT" && find . -path ./var/log/gaia -prune -o -path ./run/gaia.lock -prune -o -print0 |
    sort -z | xargs -0 env PATH="$STUB_REAL_PATH" stat -c '%n %a %F %s %Y' 2>/dev/null) |
    sed -E 's/^(.* directory) [0-9]+ [0-9]+$/\1/'
}
