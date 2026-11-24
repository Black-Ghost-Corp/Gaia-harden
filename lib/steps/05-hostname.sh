# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: host name (GAIA_HOSTNAME) in hostnamectl, /etc/hosts and preserved across cloud-init reboots

step_run() {
  [[ -n $GAIA_HOSTNAME ]] || gaia_skip "GAIA_HOSTNAME not set (host name left as is)"
  local short=${GAIA_HOSTNAME%%.*} current="" hosts_file content="" line names replaced=0

  current=$(cat "$(gaia_path /etc/hostname)" 2>/dev/null || true)
  if [[ $current == "$short" ]]; then
    gaia_info "host name already correct" "hostname=$short"
  elif command -v hostnamectl >/dev/null 2>&1; then
    gaia_run hostnamectl set-hostname "$short"
  else
    gaia_ensure_file /etc/hostname 0644 "$short"
  fi

  # Debian convention: the host name resolves through a 127.0.1.1 line in /etc/hosts.
  names=$short
  [[ $GAIA_HOSTNAME != "$short" ]] && names="$GAIA_HOSTNAME $short"
  hosts_file=$(gaia_path /etc/hosts)
  if [[ -f $hosts_file ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ ^127\.0\.1\.1[[:space:]] ]]; then
        ((replaced)) && continue
        line="127.0.1.1 $names"
        replaced=1
      fi
      content+="$line"$'\n'
    done <"$hosts_file"
  else
    content+=$'127.0.0.1 localhost\n'
  fi
  ((replaced)) || content+="127.0.1.1 $names"$'\n'
  gaia_ensure_file /etc/hosts 0644 "${content%$'\n'}"

  # cloud-init (most VPS images) would put the provider's name back on the next boot.
  if [[ -d $(gaia_path /etc/cloud) ]]; then
    gaia_ensure_file /etc/cloud/cloud.cfg.d/99-gaia-hostname.cfg 0644 "# Managed by Gaia (hostname step).
preserve_hostname: true"
  fi
  gaia_info "host name configured" "hostname=$GAIA_HOSTNAME"
}
