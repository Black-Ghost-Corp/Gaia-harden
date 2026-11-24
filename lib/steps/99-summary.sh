# shellcheck shell=bash
# gaia-description: what is listening now, what was closed, and the next steps (test SSH in a NEW session)

summary__ports() {
  local after
  [[ -n ${GAIA_RUN_DIR:-} ]] || return 0
  after=$GAIA_RUN_DIR/ports-after
  if ! gaia_ports_snapshot >"$after"; then
    gaia_info "listening sockets not audited ('ss' from iproute2 is not available)"
    return 0
  fi
  gaia_ports_report "$after" after
  if [[ -s $GAIA_RUN_DIR/ports-before ]]; then
    local proto addr port proc
    while read -r proto addr port proc; do
      [[ -n $proto ]] && gaia_info "no longer listening" "proto=$proto" "address=$addr" "port=$port" "process=$proc"
    done < <(comm -23 "$GAIA_RUN_DIR/ports-before" "$after")
  fi
  if ((GAIA_PORTS_EXPOSED > 0)); then
    gaia_warn "some sockets are reachable from the internet without a firewall rule; see the 'EXPOSED' lines above"
  fi
}

step_run() {
  local u=${GAIA_ADMIN_USER:-<admin>} ip
  ip=$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)
  ip=${ip:-<server-ip>}
  gaia_is_dry_run || summary__ports
  gaia_info "next step 1: open a NEW session and test: ssh -p $GAIA_SSH_PORT $u@$ip (do NOT close this session before logging in through the new one)"
  if gaia_module_selected docker; then
    gaia_info "next step 2: in the new session, check 'sudo -v' and 'docker ps' (the docker group applies from that login on)"
  else
    gaia_info "next step 2: in the new session, check 'sudo -v'"
  fi
  if [[ $GAIA_ADMIN_SUDO_NOPASSWD != 1 ]]; then
    gaia_info "next step 3: if the administrator has no password, set one now as root: passwd $u (sudo asks for it)"
  fi
  if [[ -f $(gaia_path /var/run/reboot-required) ]]; then
    gaia_warn "the system asks for a reboot; reboot after confirming access through the new session"
  fi
  gaia_info "modules on this server" "modules=${GAIA_MODULES:-none}"
  gaia_info "full log of this run" "file=${GAIA_LOG_FILE#"$GAIA_ROOT"}"
}
