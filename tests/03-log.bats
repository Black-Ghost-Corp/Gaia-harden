#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# Logging: line format, file in /var/log/gaia, debug, summary, secrets and the error trap.

load test_helper

@test "every output line follows [gaia][level][step=...]" {
  gaia --only preflight,time
  assert_success
  run bash -c "printf '%s\n' \"\$1\" | grep -Ev '^\[gaia\]\[(info|warn|error|debug)\]\[step=[a-z0-9:_-]+\] ' || true" _ "$output"
  assert_output ""
}

@test "writes the log to /var/log/gaia/gaia-<UTC>.log with mode 600" {
  gaia --only preflight
  assert_success
  run ls "$FAKE_ROOT/var/log/gaia/"
  assert_output --regexp '^gaia-[0-9]{8}T[0-9]{6}Z\.log$'
  local file
  file=$(ls "$FAKE_ROOT"/var/log/gaia/gaia-*.log)
  run env PATH="$STUB_REAL_PATH" stat -c %a "$file"
  assert_output 600
  run grep -c 'step=preflight' "$file"
  refute_output 0
}

@test "the log file has the debug lines even without GAIA_DEBUG; the screen does not" {
  gaia --only time
  assert_success
  refute_output --partial '[debug]'
  run grep -c '\[debug\]' "$FAKE_ROOT"/var/log/gaia/gaia-*.log
  refute_output 0
}

@test "GAIA_DEBUG=1 shows the debug lines on screen" {
  export GAIA_DEBUG=1
  gaia --only time
  assert_success
  assert_output --partial '[debug]'
}

@test "each step logs its duration and the final summary has the status table" {
  gaia --only preflight,time
  assert_success
  assert_output --regexp '\[step=preflight\] step finished status=ok duration=[0-9]+\.[0-9]{3}s'
  assert_output --regexp '\[step=time\] step finished status=done duration='
  assert_status preflight ok
  assert_status time 'done'
  assert_status ssh skipped
  assert_status docker skipped
  assert_output --regexp 'run finished.*failures=0'
}

@test "a private key pasted by mistake in GAIA_ADMIN_SSH_KEYS never reaches the log" {
  cat >>"$CONF" <<'EOF'
GAIA_ADMIN_SSH_KEYS="-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQTOPSECRETMATERIAL
-----END OPENSSH PRIVATE KEY-----"
EOF
  gaia --only admin-user
  assert_failure
  assert_output --partial 'private key'
  refute_output --partial 'TOPSECRETMATERIAL'
  run cat "$FAKE_ROOT"/var/log/gaia/gaia-*.log
  refute_output --partial 'TOPSECRETMATERIAL'
  refute_output --partial 'BEGIN OPENSSH PRIVATE KEY'
}

@test "values with a secret-looking name are masked in the log (k=v and inside messages)" {
  mkdir -p "$BATS_TEST_TMPDIR/extras"
  cat >"$BATS_TEST_TMPDIR/extras/10-secret.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck source=/dev/null
source "$GAIA_LIB_DIR/common.sh"
gaia_step_mode
gaia_info "connecting to the database" user=app password=SuperSecret1 AUTH_SIGNING_KEY=xyzabc
gaia_info "line with POSTGRES_PASSWORD=OtherSecret2 inside"
EOF
  chmod +x "$BATS_TEST_TMPDIR/extras/10-secret.sh"
  conf "GAIA_EXTRA_STEPS_DIR=$BATS_TEST_TMPDIR/extras"
  gaia --only custom:secret
  assert_success
  assert_output --partial 'user=app password=*** AUTH_SIGNING_KEY=***'
  assert_output --partial 'POSTGRES_PASSWORD=***'
  refute_output --partial 'SuperSecret1'
  refute_output --partial 'OtherSecret2'
  refute_output --partial 'xyzabc'
  run cat "$FAKE_ROOT"/var/log/gaia/gaia-*.log
  refute_output --partial 'SuperSecret1'
  refute_output --partial 'OtherSecret2'
}

@test "the error trap reports step, file and line of the failing command" {
  mkdir -p "$BATS_TEST_TMPDIR/steps"
  cat >"$BATS_TEST_TMPDIR/steps/01-broken.sh" <<'EOF'
# gaia-description: test step that fails
step_run() {
  gaia_info "before the failure"
  false
  gaia_info "never gets here"
}
EOF
  export GAIA_STEPS_DIR=$BATS_TEST_TMPDIR/steps GAIA_MODULES_DIR=$BATS_TEST_TMPDIR/none
  gaia
  assert_failure
  assert_output --regexp '\[gaia\]\[error\]\[step=broken\] command failed file=[^ ]*01-broken.sh line=4 code=1 command=false'
  refute_output --partial 'never gets here'
  assert_status broken failed
}

@test "a failing step stops the following ones (shown as skipped)" {
  mkdir -p "$BATS_TEST_TMPDIR/steps"
  printf '# gaia-description: fails\nstep_run() { gaia_fail "it broke"; }\n' >"$BATS_TEST_TMPDIR/steps/01-first.sh"
  printf '# gaia-description: after\nstep_run() { gaia_info "second ran"; }\n' >"$BATS_TEST_TMPDIR/steps/02-second.sh"
  export GAIA_STEPS_DIR=$BATS_TEST_TMPDIR/steps GAIA_MODULES_DIR=$BATS_TEST_TMPDIR/none
  gaia
  assert_failure
  assert_status first failed
  assert_status second skipped
  refute_output --partial 'second ran'
}

@test "masking does not break ordinary messages (password: in text, NOPASSWD=1)" {
  mkdir -p "$BATS_TEST_TMPDIR/extras"
  cat >"$BATS_TEST_TMPDIR/extras/10-text.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck source=/dev/null
source "$GAIA_LIB_DIR/common.sh"
gaia_info "user without password: sudo will ask" GAIA_ADMIN_SUDO_NOPASSWD=1
EOF
  chmod +x "$BATS_TEST_TMPDIR/extras/10-text.sh"
  conf "GAIA_EXTRA_STEPS_DIR=$BATS_TEST_TMPDIR/extras"
  gaia --only custom:text
  assert_success
  assert_output --partial 'user without password: sudo will ask GAIA_ADMIN_SUDO_NOPASSWD=1'
}
