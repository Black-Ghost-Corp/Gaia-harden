# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: swap file (GAIA_SWAP_SIZE) for small VPS, with low swappiness

step_run() {
  [[ -n $GAIA_SWAP_SIZE ]] || gaia_skip "GAIA_SWAP_SIZE not set (no swap file)"
  if gaia_in_container; then
    gaia_skip "running inside a container: swap belongs to the host"
  fi
  # GAIA_SWAP_FILE comes from gaia_config_defaults (lib/config.sh).
  # shellcheck disable=SC2153
  local file=$GAIA_SWAP_FILE real active fstab current
  real=$(gaia_path "$file")
  active=$(swapon --show=NAME --noheadings 2>/dev/null || true)

  if grep -qxF "$file" <<<"$active"; then
    gaia_info "swap file already active" "file=$file"
  elif [[ -n ${active//[[:space:]]/} ]]; then
    gaia_info "the system already has swap; no swap file created" "swap=${active//$'\n'/,}"
    return 0
  else
    [[ -f $real ]] || gaia_run fallocate -l "$GAIA_SWAP_SIZE" "$real"
    gaia_run chmod 600 "$real"
    gaia_run mkswap "$real"
    gaia_run swapon "$real"
  fi

  fstab=$(gaia_path /etc/fstab)
  current=$(cat "$fstab" 2>/dev/null || true)
  if ! grep -Eq "^[[:space:]]*${file}[[:space:]]+none[[:space:]]+swap" <<<"$current"; then
    if [[ -n $current ]]; then current+=$'\n'; fi
    gaia_ensure_file /etc/fstab 0644 "$current$file none swap sw 0 0"
  fi

  gaia_ensure_file /etc/sysctl.d/91-gaia-swap.conf 0644 "# Managed by Gaia (swap step): prefer RAM, use swap only under pressure.
vm.swappiness = $GAIA_SWAPPINESS"
  if ((GAIA_CHANGED)); then
    gaia_run sysctl -q -p "$(gaia_path /etc/sysctl.d/91-gaia-swap.conf)"
  fi
  gaia_info "swap configured" "file=$file" "size=$GAIA_SWAP_SIZE" "swappiness=$GAIA_SWAPPINESS"
}
