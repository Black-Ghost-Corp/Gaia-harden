# shellcheck shell=bash
# gaia-description: AppArmor (mandatory access control) enabled and loading its profiles

step_run() {
  [[ $GAIA_APPARMOR == 1 ]] || gaia_skip "AppArmor step disabled (GAIA_APPARMOR=0)"
  if gaia_in_container; then
    gaia_skip "running inside a container: AppArmor belongs to the host"
  fi
  local enabled profiles enforce
  enabled=$(cat "$(gaia_path /sys/module/apparmor/parameters/enabled)" 2>/dev/null || true)
  if [[ $enabled != Y ]]; then
    gaia_warn "AppArmor is disabled in the kernel; enable it on the kernel command line (apparmor=1 security=apparmor) and reboot"
    gaia_skip "AppArmor not available in the running kernel"
  fi
  if systemctl is-enabled --quiet apparmor 2>/dev/null && systemctl is-active --quiet apparmor 2>/dev/null; then
    gaia_info "AppArmor service already enabled"
  else
    gaia_run systemctl enable --now apparmor
  fi
  profiles=$(gaia_path /sys/kernel/security/apparmor/profiles)
  if [[ -r $profiles ]]; then
    enforce=$(grep -c '(enforce)' "$profiles" || true)
    gaia_info "AppArmor active" "profiles=$(wc -l <"$profiles")" "enforce=$enforce"
  fi
}
