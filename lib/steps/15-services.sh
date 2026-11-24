# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: turns off network services a server rarely needs (rpcbind, avahi, cups) and keeps the local mail server on loopback
#
# Only units that are actually enabled or running are touched. Extra units: GAIA_DISABLE_SERVICES.
# Set GAIA_DISABLE_UNUSED_SERVICES=0 to keep the default list running (e.g. an NFS client needs rpcbind).

SERVICES__UNUSED=(rpcbind.socket rpcbind.service avahi-daemon.socket avahi-daemon.service
  cups.socket cups.path cups.service cups-browsed.service)

services__disable() {
  local unit=$1 enabled active=0
  enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
  systemctl is-active --quiet "$unit" 2>/dev/null && active=1
  if [[ $enabled == enabled || $active == 1 ]]; then
    gaia_run systemctl disable --now "$unit"
    gaia_info "service turned off" "unit=$unit"
  else
    gaia_debug "service not enabled nor running" "unit=$unit"
  fi
}

# Postfix and Exim are often installed as dependencies; they only need to deliver local mail.
services__mta_local_only() {
  if gaia_package_installed postfix && command -v postconf >/dev/null 2>&1; then
    local current
    current=$(postconf -h inet_interfaces 2>/dev/null || true)
    case $current in
      loopback-only | localhost | 127.0.0.1 | "127.0.0.1, [::1]")
        gaia_info "postfix already listens on loopback only" "inet_interfaces=$current"
        ;;
      *)
        gaia_run postconf -e inet_interfaces=loopback-only
        gaia_run systemctl restart postfix
        ;;
    esac
  fi
  local conf content
  conf=$(gaia_path /etc/exim4/update-exim4.conf.conf)
  if [[ -f $conf ]]; then
    content=$(sed "s/^dc_local_interfaces=.*/dc_local_interfaces='127.0.0.1 ; ::1'/" "$conf")
    grep -q '^dc_local_interfaces=' <<<"$content" || content+=$'\n'"dc_local_interfaces='127.0.0.1 ; ::1'"
    gaia_ensure_file /etc/exim4/update-exim4.conf.conf 0644 "$content"
    if ((GAIA_CHANGED)); then
      gaia_run update-exim4.conf
      gaia_run systemctl restart exim4
    else
      gaia_info "exim4 already listens on loopback only"
    fi
  fi
}

step_run() {
  local unit
  if [[ $GAIA_DISABLE_UNUSED_SERVICES == 1 ]]; then
    for unit in "${SERVICES__UNUSED[@]}"; do services__disable "$unit"; done
  else
    gaia_info "default list of unused services kept (GAIA_DISABLE_UNUSED_SERVICES=0)"
  fi
  for unit in $GAIA_DISABLE_SERVICES; do services__disable "$unit"; done
  if [[ $GAIA_MTA_LOCAL_ONLY == 1 ]]; then
    services__mta_local_only
  fi
}
