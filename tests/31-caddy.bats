#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# caddy module: official repository, generated and validated Caddyfile, 80/443 in ufw, service.

load test_helper

CF=/etc/caddy/Caddyfile

setup_caddy() {
  conf 'GAIA_CADDY_SITES="app.example.com=127.0.0.1:8080"'
}

@test "not selected by default: the module does not run" {
  gaia
  assert_success
  assert_status caddy 'not selected'
  [[ ! -e $FAKE_ROOT$CF ]]
}

@test "fresh machine: verified key, official repository, caddy, Caddyfile, 80/443 and service" {
  setup_caddy
  gaia --only caddy
  assert_success
  assert_called '^curl -fsSL .*https://dl.cloudsmith.io/public/caddy/stable/gpg.key'
  [[ -f $FAKE_ROOT/etc/apt/keyrings/caddy.asc ]]
  run cat "$FAKE_ROOT/etc/apt/sources.list.d/caddy-stable.list"
  assert_output "deb [signed-by=/etc/apt/keyrings/caddy.asc] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main"
  assert_called '^apt-get .*install caddy$'
  assert_called '^caddy validate --adapter caddyfile --config '
  assert_called '^ufw allow 80/tcp$'
  assert_called '^ufw allow 443/tcp$'
  assert_called '^systemctl enable --now caddy$'
  [[ -d $FAKE_ROOT/etc/caddy/sites.d ]]
  run cat "$FAKE_ROOT$CF"
  assert_output --partial $'app.example.com {\n\timport gaia_blocks\n\timport gaia_headers\n\treverse_proxy 127.0.0.1:8080 {\n\t\tflush_interval -1\n\t}'
  assert_output --partial 'import /etc/caddy/sites.d/*.caddy'
  assert_output --partial 'Strict-Transport-Security "max-age=31536000"'
  assert_output --partial $'\t\t-Server'
  refute_output --partial 'email'
  # No compression on the proxied responses: it would hold back server-sent events.
  refute_output --partial 'encode'
}

@test "GAIA_CADDY_BLOCK_PATHS answers 403 on every site; the snippet comes before the sites" {
  setup_caddy
  conf 'GAIA_CADDY_BLOCK_PATHS="/internal /internal/*"'
  gaia --only caddy
  assert_success
  assert_output --partial 'paths blocked (403) on every site'
  run cat "$FAKE_ROOT$CF"
  assert_output --partial $'(gaia_blocks) {\n\t@gaia_blocked path /internal /internal/*\n\trespond @gaia_blocked 403\n}'
  local f=$FAKE_ROOT$CF
  (($(grep -n '^(gaia_blocks)' "$f" | cut -d: -f1) < $(grep -n '^app.example.com' "$f" | cut -d: -f1)))
}

@test "no blocked paths: empty snippet" {
  setup_caddy
  gaia --only caddy
  assert_success
  run cat "$FAKE_ROOT$CF"
  assert_output --partial $'(gaia_blocks) {\n}'
}

@test "h2c upstream (gRPC), ACME e-mail and several sites" {
  conf 'GAIA_CADDY_SITES="a.example.com=127.0.0.1:8080 grpc.example.com=h2c://127.0.0.1:9000"' GAIA_CADDY_EMAIL=ops@example.com
  gaia --only caddy
  assert_success
  run cat "$FAKE_ROOT$CF"
  assert_output --partial $'{\n\temail ops@example.com\n}'
  assert_output --partial $'a.example.com {\n\timport gaia_blocks'
  assert_output --partial $'grpc.example.com {\n\timport gaia_blocks\n\timport gaia_headers\n\treverse_proxy h2c://127.0.0.1:9000 {'
}

@test "no sites: warns that only sites.d is served" {
  gaia --only caddy
  assert_success
  assert_output --regexp 'warn.*GAIA_CADDY_SITES is empty'
}

@test "a GPG key with the wrong fingerprint aborts without installing the repository" {
  setup_caddy
  echo "WRONG-KEY" >"$STUB_STATE/caddy_key"
  gaia --only caddy
  assert_failure
  assert_output --partial 'expected fingerprint'
  [[ ! -e $FAKE_ROOT/etc/apt/keyrings/caddy.asc ]]
  [[ ! -e $FAKE_ROOT/etc/apt/sources.list.d/caddy-stable.list ]]
}

@test "second run changes nothing and does not reload" {
  setup_caddy
  gaia --only caddy
  assert_success
  active_unit caddy
  installed_packages caddy
  clear_calls
  gaia --only caddy
  assert_success
  assert_status caddy ok
  assert_no_mutation
  refute_called '^systemctl reload caddy'
}

@test "a new site with caddy running: Caddyfile replaced and reload, no restart" {
  setup_caddy
  gaia --only caddy
  assert_success
  active_unit caddy
  installed_packages caddy
  clear_calls
  conf 'GAIA_CADDY_SITES="app.example.com=127.0.0.1:8080 new.example.com=127.0.0.1:9000"'
  gaia --only caddy
  assert_success
  assert_called '^systemctl reload caddy$'
  refute_called '^systemctl (restart|enable)'
  run cat "$FAKE_ROOT$CF"
  assert_output --partial 'new.example.com {'
}

@test "caddy validate rejects: the current Caddyfile stays and the step fails" {
  setup_caddy
  gaia --only caddy
  assert_success
  local before
  before=$(cat "$FAKE_ROOT$CF")
  conf 'GAIA_CADDY_SITES="other.example.com=127.0.0.1:9000"'
  force_failure caddy_validate
  gaia --only caddy
  assert_failure
  assert_output --partial 'invalid Caddyfile; the current one was kept'
  [[ $(cat "$FAKE_ROOT$CF") == "$before" ]]
}

@test "80/443 rules that already exist are not added again" {
  setup_caddy
  printf 'ufw allow 80/tcp\nufw allow 443/tcp\n' >"$STUB_STATE/ufw/rules"
  gaia --only caddy
  assert_success
  refute_called '^ufw allow'
}

@test "dry-run on a fresh machine: shows what it would do and changes nothing" {
  setup_caddy
  local before
  before=$(root_snapshot)
  gaia --dry-run --only caddy
  assert_success
  assert_no_mutation
  [[ $(root_snapshot) == "$before" ]]
  assert_status caddy 'would change'
}

@test "validation: malformed site, duplicate domain, bad e-mail and bad path are refused" {
  conf 'GAIA_CADDY_SITES="app.example.com"'
  gaia --dry-run --only caddy
  assert_failure
  assert_output --partial 'invalid value in GAIA_CADDY_SITES'

  write_conf
  conf 'GAIA_CADDY_SITES="a.example.com=127.0.0.1:1 a.example.com=127.0.0.1:2"'
  gaia --dry-run --only caddy
  assert_failure
  assert_output --partial 'duplicate domain'

  write_conf
  conf GAIA_CADDY_EMAIL=not-an-email
  gaia --dry-run --only caddy
  assert_failure
  assert_output --partial 'invalid value for GAIA_CADDY_EMAIL'

  write_conf
  conf 'GAIA_CADDY_BLOCK_PATHS="api/no-slash"'
  gaia --dry-run --only caddy
  assert_failure
  assert_output --partial 'invalid value in GAIA_CADDY_BLOCK_PATHS'
}
