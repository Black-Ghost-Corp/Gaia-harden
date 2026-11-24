# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: unattended-upgrades with security updates only; automatic reboot off by default
#
# The 52gaia-* file is read after the package's 50unattended-upgrades. The "#clear" lines (apt.conf
# syntax) drop the origins defined before, so that ONLY the security origin is left.

auto_updates__origins() {
  # ${distro_codename} is expanded by unattended-upgrades, not by the shell.
  # shellcheck disable=SC2016
  case $GAIA_OS_ID in
    ubuntu)
      printf '        "%s";\n' 'origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu' \
        'origin=UbuntuESMApps,archive=${distro_codename}-apps-security' \
        'origin=UbuntuESM,archive=${distro_codename}-infra-security'
      ;;
    debian)
      printf '        "%s";\n' 'origin=Debian,codename=${distro_codename}-security,label=Debian-Security'
      ;;
  esac
}

step_run() {
  local reboot=false
  [[ $GAIA_AUTO_REBOOT == 1 ]] && reboot=true

  gaia_ensure_file /etc/apt/apt.conf.d/20auto-upgrades 0644 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'

  gaia_ensure_file /etc/apt/apt.conf.d/52gaia-unattended-upgrades 0644 "// Managed by Gaia (auto-updates step): security updates only.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
$(auto_updates__origins)
};
Unattended-Upgrade::Automatic-Reboot \"$reboot\";
Unattended-Upgrade::Automatic-Reboot-Time \"$GAIA_AUTO_REBOOT_TIME\";"

  if [[ $reboot == true ]]; then
    gaia_info "automatic security updates with reboot" "time=$GAIA_AUTO_REBOOT_TIME"
  else
    gaia_info "automatic security updates, without automatic reboot (see /var/run/reboot-required)"
  fi
}
