#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# audit-before / audit-after steps: Lynis hardening index before and after.

load test_helper

@test "installs Lynis, records the baseline and shows the gain at the end" {
  printf '%s\n' 55 78 >"$STUB_STATE/lynis_scores"
  gaia --only audit-before,audit-after
  assert_success
  assert_called '^apt-get .*install --no-install-recommends lynis$'
  assert_output --regexp 'Lynis hardening index phase=before index=55'
  assert_output --partial 'Lynis hardening index: 55 -> 78 (+23)'
  run cat "$FAKE_ROOT/var/lib/gaia/audit/history"
  assert_output --regexp 'before=55 after=78'
  run env PATH="$STUB_REAL_PATH" stat -c %a "$FAKE_ROOT/var/lib/gaia/audit"
  assert_output 700
}

@test "--no-audit / GAIA_AUDIT=0 skips both audits" {
  gaia --only audit-before,audit-after --no-audit
  assert_success
  assert_status audit-before skipped
  assert_status audit-after skipped
  refute_called 'lynis'
}

@test "dry-run does not run Lynis" {
  gaia --dry-run --only audit-before,audit-after
  assert_success
  refute_called '^lynis'
  assert_output --partial "[dry-run] would run 'lynis audit system'"
}

@test "a Lynis failure is a warning, not a failed run" {
  force_failure lynis 1
  gaia --only audit-before
  assert_success
  assert_output --regexp 'warn.*Lynis did not produce a report'
}
