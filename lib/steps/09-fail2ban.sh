# shellcheck shell=bash
# gaia-description: fail2ban with the sshd jail on the configured port

GAIA_FAIL2BAN_JAIL=/etc/fail2ban/jail.d/gaia.local

fail2ban__content() {
  cat <<EOF
# Managed by Gaia (fail2ban step). Change gaia.conf and run Gaia again.
[DEFAULT]
bantime = $GAIA_FAIL2BAN_BANTIME
findtime = $GAIA_FAIL2BAN_FINDTIME
maxretry = $GAIA_FAIL2BAN_MAXRETRY
ignoreip = $GAIA_FAIL2BAN_IGNOREIP

[sshd]
enabled = true
port = $GAIA_SSH_PORT
backend = $GAIA_FAIL2BAN_BACKEND
EOF
}

step_run() {
  gaia_ensure_checked_file "$GAIA_FAIL2BAN_JAIL" 0644 "$(fail2ban__content)" "fail2ban-client -t" fail2ban-client -t
  local changed=$GAIA_CHANGED

  if systemctl is-enabled --quiet fail2ban 2>/dev/null && systemctl is-active --quiet fail2ban 2>/dev/null; then
    if ((changed)); then
      gaia_run systemctl reload fail2ban
    else
      gaia_info "fail2ban already active and configured" "port=$GAIA_SSH_PORT"
    fi
  else
    gaia_run systemctl enable --now fail2ban
  fi
}
