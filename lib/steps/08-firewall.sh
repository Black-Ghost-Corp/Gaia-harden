# shellcheck shell=bash
# gaia-description: ufw denying inbound by default, SSH rate-limited and allowed before enabling, plus GAIA_FIREWALL_ALLOW
#
# Note: ports published by Docker containers do NOT go through ufw by default, because Docker inserts
# its own iptables rules before ufw's. The docker module fixes that (GAIA_DOCKER_UFW=1).

firewall__policy() {
  local key=$1 file
  file=$(gaia_path /etc/default/ufw)
  [[ -f $file ]] || return 0
  sed -n "s/^$key=\"\{0,1\}\([A-Z]*\)\"\{0,1\}.*/\1/p" "$file" | head -n1
}

step_run() {
  if ! command -v ufw >/dev/null 2>&1; then
    if gaia_is_dry_run; then
      gaia_warn "dry-run: ufw not installed yet (the packages step installs it); showing what would be done from scratch"
    else
      gaia_fail "ufw is not installed; run the packages step first"
    fi
  fi

  if [[ $(firewall__policy DEFAULT_INPUT_POLICY) == DROP ]]; then
    gaia_info "inbound already denied by default"
  else
    gaia_run ufw default deny incoming
  fi
  if [[ $(firewall__policy DEFAULT_OUTPUT_POLICY) == ACCEPT ]]; then
    gaia_info "outbound already allowed by default"
  else
    gaia_run ufw default allow outgoing
  fi

  # SSH first: the firewall must never come up without the administration port open. "limit"
  # also allows it, but blocks an address that opens 6+ connections within 30 seconds.
  if [[ $GAIA_SSH_RATE_LIMIT == 1 ]]; then
    gaia_ufw_ensure limit "$GAIA_SSH_PORT/tcp"
  else
    gaia_ufw_ensure allow "$GAIA_SSH_PORT/tcp"
  fi
  local added
  added=$(ufw show added 2>/dev/null || true)
  if [[ $GAIA_SSH_PORT != 22 ]] && grep -qE '^ufw (allow|limit) 22/tcp$' <<<"$added"; then
    gaia_warn "the old 22/tcp rule is still in ufw; remove it with 'ufw delete allow 22/tcp' (or 'limit') after testing SSH on port $GAIA_SSH_PORT"
  fi

  local rule
  for rule in $GAIA_FIREWALL_ALLOW; do
    gaia_ufw_ensure allow "$rule"
  done

  if gaia_ufw_active; then
    gaia_info "ufw already active"
  else
    gaia_run ufw --force enable
  fi
  gaia_info "firewall configured" "ssh=$GAIA_SSH_PORT/tcp" "ssh_rate_limit=$GAIA_SSH_RATE_LIMIT" "allowed=${GAIA_FIREWALL_ALLOW:-none}"
}
