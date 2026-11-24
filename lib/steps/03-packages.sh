# shellcheck shell=bash
# gaia-description: apt update, full-upgrade (configurable) and the base packages, no questions asked

packages__list() {
  local -a list=(ca-certificates curl gnupg jq iproute2 ufw fail2ban python3-systemd unattended-upgrades
    sudo openssh-server tzdata)
  list+=("$(gaia_ntp_package)")
  [[ $GAIA_APPARMOR == 1 ]] && list+=(apparmor)
  local extra
  for extra in $GAIA_EXTRA_PACKAGES; do list+=("$extra"); done
  printf '%s\n' "${list[@]}"
}

step_run() {
  gaia_apt_update

  if [[ $GAIA_APT_FULL_UPGRADE == 1 ]]; then
    local n
    n=$(apt-get -s "${GAIA_APT_OPTS[@]}" full-upgrade 2>/dev/null | grep -c '^Inst ' || true)
    if ((n > 0)); then
      gaia_info "updates available" "packages=$n"
      gaia_run apt-get "${GAIA_APT_OPTS[@]}" full-upgrade
    else
      gaia_info "system is up to date"
    fi
  else
    gaia_info "full-upgrade disabled (GAIA_APT_FULL_UPGRADE=0)"
  fi

  local p
  local -a missing=()
  while IFS= read -r p; do
    if gaia_package_installed "$p"; then
      gaia_debug "package already installed" "package=$p"
    else
      missing+=("$p")
    fi
  done < <(packages__list)
  if ((${#missing[@]})); then
    gaia_info "installing packages" "packages=${missing[*]}"
    gaia_run apt-get "${GAIA_APT_OPTS[@]}" install --no-install-recommends "${missing[@]}"
  else
    gaia_info "all base packages are already installed"
  fi

  if [[ -f $(gaia_path /var/run/reboot-required) ]]; then
    gaia_warn "the system asks for a reboot (kernel or libraries updated); reboot when you can"
  fi
}
