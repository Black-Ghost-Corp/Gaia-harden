# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: time zone (GAIA_TIMEZONE) and NTP time synchronization enabled

step_run() {
  local current package
  if [[ ! -f $(gaia_path "/usr/share/zoneinfo/$GAIA_TIMEZONE") ]]; then
    if gaia_is_dry_run && [[ ! -d $(gaia_path /usr/share/zoneinfo) ]]; then
      gaia_warn "dry-run: tzdata not installed yet (the packages step installs it); cannot check the time zone" "timezone=$GAIA_TIMEZONE"
    else
      gaia_fail "unknown time zone: $GAIA_TIMEZONE (see timedatectl list-timezones)"
    fi
  fi

  # timedatectl ships with systemd. Without it (container, system without systemd) there is no
  # supported way to read or set the time zone and NTP: dry-run only warns; a real run fails clearly.
  if ! command -v timedatectl >/dev/null 2>&1; then
    if gaia_is_dry_run; then
      gaia_warn "dry-run: timedatectl not found (no systemd); time zone and NTP not checked" "timezone=$GAIA_TIMEZONE"
      return 0
    fi
    gaia_fail "timedatectl not found: the time step requires systemd; timezone=$GAIA_TIMEZONE"
  fi

  current=$(timedatectl show -p Timezone --value)
  if [[ $current == "$GAIA_TIMEZONE" ]]; then
    gaia_info "time zone already correct" "timezone=$current"
  else
    gaia_info "setting the time zone" "current=$current" "new=$GAIA_TIMEZONE"
    gaia_run timedatectl set-timezone "$GAIA_TIMEZONE"
  fi

  package=$(gaia_ntp_package)
  if [[ $package == chrony ]]; then
    if systemctl is-enabled --quiet chrony 2>/dev/null && systemctl is-active --quiet chrony 2>/dev/null; then
      gaia_info "NTP already enabled" "service=chrony"
    else
      gaia_run systemctl enable --now chrony
    fi
  else
    if [[ $(timedatectl show -p NTP --value) == yes ]]; then
      gaia_info "NTP already enabled" "service=systemd-timesyncd"
    else
      gaia_run timedatectl set-ntp true
    fi
  fi
}
