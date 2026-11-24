# shellcheck shell=bash
# gaia-description: Lynis security audit before any change (baseline hardening index)

# shellcheck source=../audit.sh
source "$GAIA_HOME/lib/audit.sh"

step_run() {
  gaia_audit_should_run
  gaia_apt_install lynis
  if gaia_is_dry_run; then
    gaia_info "[dry-run] would run 'lynis audit system' and record the hardening index"
    return 0
  fi
  gaia_audit_run before
}
