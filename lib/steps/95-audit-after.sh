# shellcheck shell=bash
# gaia-description: Lynis security audit after the changes, compared with the baseline

# shellcheck source=../audit.sh
source "$GAIA_HOME/lib/audit.sh"

step_run() {
  gaia_audit_should_run
  if gaia_is_dry_run; then
    gaia_info "[dry-run] would run 'lynis audit system' again and compare the hardening index"
    return 0
  fi
  command -v lynis >/dev/null 2>&1 || gaia_skip "lynis is not installed (the audit-before step installs it)"
  local before="" dir
  dir=$(gaia_path "$GAIA_AUDIT_DIR")
  before=$(cat "$dir/score-before" 2>/dev/null || true)
  gaia_audit_run after
  local after=$GAIA_AUDIT_SCORE
  if [[ $before =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]; then
    local delta=$((after - before)) sign=""
    ((delta >= 0)) && sign=+
    gaia_info "Lynis hardening index: $before -> $after ($sign$delta)" "before=$before" "after=$after"
    printf '%s before=%s after=%s gaia=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$before" "$after" "$GAIA_VERSION" >>"$dir/history"
  fi
  gaia_info "full report: sudo lynis show details <TEST-ID>; raw data in $GAIA_AUDIT_DIR"
}
