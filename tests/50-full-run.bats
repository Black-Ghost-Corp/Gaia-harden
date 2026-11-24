#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# Whole runs: dry-run on a fresh machine, two real runs in a row (the second changes nothing).

load test_helper

setup_extra() {
  printf '%s\n' 58 81 70 82 >"$STUB_STATE/lynis_scores"
}

@test "full dry-run on a fresh machine: no changing call and no file touched" {
  conf 'GAIA_MODULES="docker caddy"' 'GAIA_CADDY_SITES="app.example.com=127.0.0.1:8080"' 'GAIA_SWAP_SIZE=1G' \
    'GAIA_HOSTNAME=web-01' 'GAIA_DIRS="/srv/apps:@admin:@admin:0755"'
  local before
  before=$(root_snapshot)
  gaia --dry-run
  assert_success
  assert_no_mutation
  [[ $(root_snapshot) == "$before" ]]
  assert_status preflight ok
  assert_status ssh 'would change'
  assert_status docker 'would change'
  assert_status caddy 'would change'
  refute_output --regexp '\| [a-z:-]+ +\| failed'
}

@test "full run twice: the second changes nothing and everything is ok" {
  conf 'GAIA_MODULES="docker caddy"' 'GAIA_CADDY_SITES="app.example.com=127.0.0.1:8080"' 'GAIA_SWAP_SIZE=1G' \
    'GAIA_HOSTNAME=web-01' 'GAIA_DIRS="/srv/apps:@admin:@admin:0755"' 'GAIA_DOCKER_PUBLISH="443/tcp"'
  gaia
  assert_success
  refute_output --regexp '\| [a-z:-]+ +\| failed'
  assert_status admin-user 'done'
  assert_status docker 'done'
  assert_output --partial 'Lynis hardening index: 58 -> 81 (+23)'

  clear_calls
  gaia
  assert_success
  refute_output --regexp '\| [a-z:-]+ +\| (done|failed|would change) '
  assert_status ssh ok
  assert_status docker ok
  assert_status sysctl ok
  assert_no_mutation
}

@test "the summary says what to do next (test SSH in a NEW session)" {
  existing_admin
  gaia --only summary
  assert_success
  assert_output --partial 'open a NEW session and test: ssh -p 22 admin@'
  assert_output --partial "check 'sudo -v'"
}

@test "the summary reports what is listening and flags exposed services" {
  existing_admin
  printf '%s\n' 'tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' \
    'tcp LISTEN 0 4096 0.0.0.0:111 0.0.0.0:* users:(("rpcbind",pid=2,fd=3))' \
    'tcp LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=3,fd=3))' >"$STUB_STATE/ss"
  gaia --only firewall,summary
  assert_success
  assert_output --regexp 'listening \(after\) proto=tcp address=0.0.0.0 port=22 process=sshd exposure="public, allowed by firewall"'
  assert_output --regexp 'port=111 process=rpcbind exposure="blocked by firewall"'
  assert_output --regexp 'port=5432 process=postgres exposure="local only"'
}
