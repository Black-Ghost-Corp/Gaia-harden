# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: persistent, compressed system journal with a disk usage cap (GAIA_JOURNALD_MAX_USE)

GAIA_JOURNALD_FILE=/etc/systemd/journald.conf.d/90-gaia.conf

step_run() {
  [[ $GAIA_JOURNALD == 1 ]] || gaia_skip "journald settings disabled (GAIA_JOURNALD=0)"
  gaia_ensure_file "$GAIA_JOURNALD_FILE" 0644 "# Managed by Gaia (journald step).
# Persistent logs survive reboots (useful after an incident) and never fill the disk.
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=$GAIA_JOURNALD_MAX_USE"
  if ((GAIA_CHANGED)); then
    gaia_run systemctl restart systemd-journald
  else
    gaia_info "journald already configured" "max_use=$GAIA_JOURNALD_MAX_USE"
  fi
}
