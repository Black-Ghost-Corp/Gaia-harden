#!/usr/bin/env bats
# preflight step: only checks (disk, network, systemd) and records what is listening; never changes anything.

load test_helper

@test "a passing preflight makes no changing call" {
  gaia --only preflight
  assert_success
  assert_status preflight ok
  assert_no_mutation
}

@test "probes the apt mirrors (deb822 and sources.list) and the repositories of the selected modules" {
  echo "deb [arch=amd64] http://mirror.example.org/ubuntu noble main" >"$FAKE_ROOT/etc/apt/sources.list"
  gaia --only preflight --modules docker
  assert_success
  assert_called '^curl .*http://archive.ubuntu.com/'
  assert_called '^curl .*http://security.ubuntu.com/'
  assert_called '^curl .*http://mirror.example.org/'
  assert_called '^curl .*https://download.docker.com/'
  refute_called 'dl.cloudsmith.io'
}

@test "without the docker module, download.docker.com is not required" {
  echo download.docker.com >"$STUB_STATE/curl_fail"
  gaia --only preflight
  assert_success
  refute_called 'download.docker.com'
}

@test "an unreachable required destination fails and names it" {
  echo download.docker.com >"$STUB_STATE/curl_fail"
  gaia --only preflight --modules docker
  assert_failure
  assert_output --regexp 'error.*unreachable.*url=https://download.docker.com'
  assert_status preflight failed
}

@test "free disk below the configured minimum fails" {
  export STUB_DF_KB=$((5 * 1024 * 1024))
  conf "GAIA_MIN_DISK_GB=10"
  gaia --only preflight
  assert_failure
  assert_output --partial 'not enough free disk space'
}

@test "without systemd it fails, unless GAIA_REQUIRE_SYSTEMD=0" {
  rm -rf "$FAKE_ROOT/run/systemd"
  gaia --only preflight
  assert_failure
  assert_output --partial 'systemd'
  conf "GAIA_REQUIRE_SYSTEMD=0"
  gaia --only preflight
  assert_success
  assert_output --regexp 'warn.*systemd'
}

@test "records the listening sockets before the run" {
  gaia --only preflight
  assert_success
  assert_output --regexp 'listening \(before\) proto=tcp address=0.0.0.0 port=22 process=sshd exposure="EXPOSED \(firewall inactive\)"'
  assert_output --regexp 'listening \(before\) proto=udp address=127.0.0.53 port=53 .*exposure="local only"'
  assert_output --partial 'listening sockets (before) total=3 exposed=2 firewall=inactive'
}

@test "IPv6 addresses with brackets and a zone are parsed cleanly" {
  printf '%s\n' \
    'udp UNCONN 0 0 [fe80::216:3eff:fee6:b7a5]%enp5s0:546 [::]:* users:(("systemd-network",pid=9,fd=20))' \
    'tcp LISTEN 0 4096 [::1]:8080 [::]:* users:(("app",pid=10,fd=3))' \
    'tcp LISTEN 0 4096 [::]:22 [::]:* users:(("sshd",pid=11,fd=4))' >"$STUB_STATE/ss"
  gaia --only preflight
  assert_success
  assert_output --regexp 'proto=udp address=fe80::216:3eff:fee6:b7a5 port=546 process=systemd-network'
  assert_output --regexp 'proto=tcp address=::1 port=8080 process=app exposure="local only"'
  assert_output --regexp 'proto=tcp address=:: port=22 process=sshd'
  refute_output --regexp 'address=[^ ]*[][%]'
}

@test "inside a container, warns that host-owned settings are skipped" {
  export GAIA_CONTAINER=1
  gaia --only preflight
  assert_success
  assert_output --partial 'running inside a container'
}
