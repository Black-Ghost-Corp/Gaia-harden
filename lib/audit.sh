# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# lib/audit.sh — Lynis security audit (CISOfy), run before and after Gaia to show the
# "hardening index" gain. Sourced by the audit-before and audit-after steps.

GAIA_AUDIT_DIR=/var/lib/gaia/audit

# Runs Lynis and stores the report. $1 = before|after. Prints nothing; sets GAIA_AUDIT_SCORE.
gaia_audit_run() {
  local phase=$1 dir report log rc=0
  dir=$(gaia_path "$GAIA_AUDIT_DIR")
  mkdir -p "$dir"
  chmod 700 "$dir"
  report="$dir/lynis-$phase.dat"
  log="$dir/lynis-$phase.log"
  gaia_info "running the Lynis audit (takes a minute or two)" "phase=$phase"
  lynis audit system --quick --no-colors --report-file "$report" --logfile "$log" >"$dir/lynis-$phase.out" 2>&1 || rc=$?
  if ((rc != 0)) || [[ ! -s $report ]]; then
    gaia_warn "Lynis did not produce a report; the audit result is not available" "phase=$phase" "code=$rc"
    GAIA_AUDIT_SCORE=""
    return 0
  fi
  GAIA_AUDIT_SCORE=$(sed -n 's/^hardening_index=//p' "$report" | head -n1)
  local warnings suggestions
  warnings=$(grep -c '^warning\[\]=' "$report" || true)
  suggestions=$(grep -c '^suggestion\[\]=' "$report" || true)
  printf '%s\n' "$GAIA_AUDIT_SCORE" >"$dir/score-$phase"
  # Score of THIS run for --report-json (score files from older runs may exist).
  if [[ -n ${GAIA_RUN_DIR:-} ]]; then printf '%s\n' "$GAIA_AUDIT_SCORE" >"$GAIA_RUN_DIR/lynis-$phase"; fi
  gaia_info "Lynis hardening index" "phase=$phase" "index=${GAIA_AUDIT_SCORE:-?}" "warnings=$warnings" \
    "suggestions=$suggestions" "report=$GAIA_AUDIT_DIR/lynis-$phase.dat"
}

gaia_audit_should_run() {
  [[ $GAIA_AUDIT == 1 ]] || gaia_skip "audit disabled (GAIA_AUDIT=0 or --no-audit)"
}
