#!/usr/bin/env bats
# services step: unused network services off, mail server on loopback, directories.

load test_helper

@test "turns off rpcbind, avahi and cups only when they are enabled or running" {
  active_unit rpcbind.socket
  active_unit avahi-daemon
  touch "$STUB_STATE/units/cups.active"
  gaia --only services
  assert_success
  assert_called '^systemctl disable --now rpcbind.socket$'
  assert_called '^systemctl disable --now avahi-daemon.service$'
  assert_called '^systemctl disable --now cups.service$'
  refute_called 'disable --now rpcbind.service'
  refute_called 'disable --now cups-browsed'
  assert_status services 'done'
}

@test "nothing running: nothing to do" {
  gaia --only services
  assert_success
  assert_no_mutation
  assert_status services ok
}

@test "GAIA_DISABLE_UNUSED_SERVICES=0 keeps them; GAIA_DISABLE_SERVICES adds units" {
  active_unit rpcbind.socket
  active_unit snapd
  conf GAIA_DISABLE_UNUSED_SERVICES=0 'GAIA_DISABLE_SERVICES="snapd.service"'
  gaia --only services
  assert_success
  refute_called 'rpcbind'
  assert_called '^systemctl disable --now snapd.service$'
}

@test "postfix listening on all interfaces is moved to loopback only" {
  installed_packages postfix
  gaia --only services
  assert_success
  assert_called '^postconf -e inet_interfaces=loopback-only$'
  assert_called '^systemctl restart postfix$'
  clear_calls
  gaia --only services
  assert_no_mutation
}

@test "exim4 is moved to loopback only" {
  mkdir -p "$FAKE_ROOT/etc/exim4"
  printf "dc_eximconfig_configtype='internet'\ndc_local_interfaces=''\n" >"$FAKE_ROOT/etc/exim4/update-exim4.conf.conf"
  gaia --only services
  assert_success
  run cat "$FAKE_ROOT/etc/exim4/update-exim4.conf.conf"
  assert_line "dc_local_interfaces='127.0.0.1 ; ::1'"
  assert_line "dc_eximconfig_configtype='internet'"
  assert_called '^update-exim4.conf$'
  assert_called '^systemctl restart exim4$'
}

@test "directories: skipped without GAIA_DIRS" {
  gaia --only directories
  assert_success
  assert_status directories skipped
}

@test "directories: created with owner and mode; @admin is the administrator" {
  existing_admin
  conf 'GAIA_DIRS="/srv/apps:@admin:@admin:0755 /srv/backups:@admin:@admin:0750"'
  gaia --only directories
  assert_success
  [[ -d $FAKE_ROOT/srv/apps && -d $FAKE_ROOT/srv/backups ]]
  assert_called "^chown admin:admin $FAKE_ROOT/srv/apps$"
  run env PATH="$STUB_REAL_PATH" stat -c %a "$FAKE_ROOT/srv/backups"
  assert_output 750
  clear_calls
  gaia --only directories
  assert_no_mutation
}

@test "directories: a malformed entry is refused" {
  conf 'GAIA_DIRS="/srv/apps:admin"'
  gaia --only directories
  assert_failure
  assert_output --partial 'invalid entry in GAIA_DIRS'
}
