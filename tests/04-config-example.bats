#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia.conf.example documents every Gaia variable and, filled in, passes validation.

load test_helper

# Names of every variable with a default in lib/config.sh.
config_variables() {
  grep -oE '\$\{GAIA_[A-Z0-9_]+:?=' "$REPO/lib/config.sh" | grep -oE 'GAIA_[A-Z0-9_]+'
}

@test "every variable with a default in lib/config.sh is documented in gaia.conf.example" {
  local v missing=""
  while read -r v; do
    grep -qE "^#? ?$v=" "$REPO/gaia.conf.example" || missing+=" $v"
  done < <(config_variables)
  [[ -z $missing ]] || { echo "undocumented:$missing"; false; }
}

@test "the example's values are the same as lib/config.sh's defaults" {
  cat >"$BATS_TEST_TMPDIR/compare.sh" <<'EOF'
GAIA_HOME=/opt/gaia
source "$1/lib/common.sh"
source "$1/lib/config.sh"
mapfile -t vars < <(grep -oE '\$\{GAIA_[A-Z0-9_]+:?=' "$1/lib/config.sh" | grep -oE 'GAIA_[A-Z0-9_]+' | grep -v GAIA_EXTRA_STEPS_DIR)
dump() { local v; for v in "${vars[@]}"; do printf '%s=%s\n' "$v" "${!v}"; done; }
gaia_config_defaults
dump >"$2/defaults"
unset "${vars[@]}"
source "$1/gaia.conf.example"
gaia_config_defaults
dump >"$2/example"
diff "$2/defaults" "$2/example"
EOF
  run bash "$BATS_TEST_TMPDIR/compare.sh" "$REPO" "$BATS_TEST_TMPDIR"
  assert_success
}

@test "the example filled with a user and a key passes validation (dry-run)" {
  cp "$REPO/gaia.conf.example" "$CONF"
  sed -i "s|^GAIA_ADMIN_USER=.*|GAIA_ADMIN_USER=admin|; s|^GAIA_ADMIN_SSH_KEYS=.*|GAIA_ADMIN_SSH_KEYS=\"$PUBKEY\"|" "$CONF"
  gaia --dry-run
  assert_success
}

@test "the example without an administrator: refused with a clear message" {
  cp "$REPO/gaia.conf.example" "$CONF"
  gaia --dry-run --only admin-user
  assert_failure
  assert_output --partial 'no administrator account'
}
