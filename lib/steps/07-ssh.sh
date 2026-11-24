# shellcheck shell=bash
# gaia-description: hardens SSH through a drop-in (no root, no passwords, modern crypto, AllowUsers), with lock-out protection
#
# Protection against locking yourself out:
#   1. passwords/root login are only disabled if the administrator has at least one valid key;
#   2. the new file is checked with "sshd -t" before reloading; on failure it is rolled back;
#   3. the effective configuration ("sshd -T") is compared with the wanted one: if another file
#      wins over the drop-in, it is rolled back and the step fails;
#   4. sshd is reloaded, never restarted: the current session stays open;
#   5. if the port changes while ufw is active, the new port is opened first.
# The default file name starts with 00- because sshd keeps the FIRST value it reads, and drop-ins
# such as 50-cloud-init.conf (common on Ubuntu) turn PasswordAuthentication on.

# shellcheck source=../keys.sh
source "$GAIA_HOME/lib/keys.sh"

# Modern algorithms, strongest first. Only those supported by the installed OpenSSH are used
# ("ssh -Q"), so the same list works from Ubuntu 22.04 (OpenSSH 8.9) to the newest releases.
SSH__KEX=(mlkem768x25519-sha256 sntrup761x25519-sha512 sntrup761x25519-sha512@openssh.com curve25519-sha256
  curve25519-sha256@libssh.org diffie-hellman-group18-sha512 diffie-hellman-group16-sha512)
SSH__CIPHERS=(chacha20-poly1305@openssh.com aes256-gcm@openssh.com aes128-gcm@openssh.com aes256-ctr aes192-ctr aes128-ctr)
SSH__MACS=(hmac-sha2-512-etm@openssh.com hmac-sha2-256-etm@openssh.com umac-128-etm@openssh.com)
# Available since OpenSSH 8.9 (oldest supported release): used when "ssh -Q" cannot be asked.
SSH__BASELINE=" sntrup761x25519-sha512@openssh.com curve25519-sha256 curve25519-sha256@libssh.org diffie-hellman-group18-sha512 diffie-hellman-group16-sha512 ${SSH__CIPHERS[*]} ${SSH__MACS[*]} "

# ssh__supported <kex|cipher|mac> <algorithms...> -> comma separated list of the supported ones.
ssh__supported() {
  local kind=$1 a out="" available=""
  shift
  if command -v ssh >/dev/null 2>&1; then available=" $(ssh -Q "$kind" 2>/dev/null | tr '\n' ' ') "; fi
  [[ -n ${available// /} ]] || available=$SSH__BASELINE
  for a in "$@"; do
    [[ $available == *" $a "* ]] && out+="${out:+,}$a"
  done
  printf '%s' "$out"
}

ssh__content() {
  local allow
  allow=$(gaia_ssh_allow_users)
  cat <<EOF
# Managed by Gaia (ssh step). Do not edit by hand: change gaia.conf and run Gaia again.
Port $GAIA_SSH_PORT
PermitRootLogin $GAIA_SSH_PERMIT_ROOT_LOGIN
PasswordAuthentication $GAIA_SSH_PASSWORD_AUTH
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
PermitUserEnvironment no
MaxAuthTries $GAIA_SSH_MAX_AUTH_TRIES
LoginGraceTime $GAIA_SSH_LOGIN_GRACE_TIME
ClientAliveInterval $GAIA_SSH_CLIENT_ALIVE_INTERVAL
ClientAliveCountMax 2
AllowTcpForwarding $GAIA_SSH_TCP_FORWARDING
AllowAgentForwarding $GAIA_SSH_AGENT_FORWARDING
X11Forwarding no
LogLevel VERBOSE
EOF
  [[ -z $allow ]] || printf 'AllowUsers %s\n' "$allow"
  if [[ $GAIA_SSH_MODERN_CRYPTO == 1 ]]; then
    printf 'KexAlgorithms %s\n' "$(ssh__supported kex "${SSH__KEX[@]}")"
    printf 'Ciphers %s\n' "$(ssh__supported cipher "${SSH__CIPHERS[@]}")"
    printf 'MACs %s\n' "$(ssh__supported mac "${SSH__MACS[@]}")"
  fi
}

# Effective value of an option according to sshd (lowercase, as "sshd -T" prints it).
ssh__effective() {
  sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { print $2; exit }' || true
}

# Seconds for a sshd time value (30, 30s, 2m, 1h).
ssh__seconds() {
  local v=$1
  case $v in
    *s) echo "${v%s}" ;;
    *m) echo $((${v%m} * 60)) ;;
    *h) echo $((${v%h} * 3600)) ;;
    *) echo "$v" ;;
  esac
}

ssh__check_effective() {
  local effective key want value ok=0
  effective=$(sshd -T 2>/dev/null || true)
  if [[ -z $effective ]]; then
    gaia_error "sshd -T did not return the effective configuration"
    return 1
  fi
  local -A expect=(
    [port]=$GAIA_SSH_PORT
    [permitrootlogin]=$GAIA_SSH_PERMIT_ROOT_LOGIN
    [passwordauthentication]=$GAIA_SSH_PASSWORD_AUTH
    [kbdinteractiveauthentication]=no
    [maxauthtries]=$GAIA_SSH_MAX_AUTH_TRIES
    [logingracetime]=$(ssh__seconds "$GAIA_SSH_LOGIN_GRACE_TIME")
    [allowtcpforwarding]=$GAIA_SSH_TCP_FORWARDING
    [allowagentforwarding]=$GAIA_SSH_AGENT_FORWARDING
  )
  [[ $GAIA_SSH_TCP_FORWARDING == all ]] && expect[allowtcpforwarding]=yes
  if [[ $GAIA_SSH_MODERN_CRYPTO == 1 ]]; then
    expect[kexalgorithms]=$(ssh__supported kex "${SSH__KEX[@]}")
    expect[ciphers]=$(ssh__supported cipher "${SSH__CIPHERS[@]}")
    expect[macs]=$(ssh__supported mac "${SSH__MACS[@]}")
  fi
  for key in "${!expect[@]}"; do
    want=${expect[$key]}
    value=$(awk -v k="$key" '$1 == k { print $2; exit }' <<<"$effective")
    # Some OpenSSH versions print prohibit-password as without-password.
    [[ $want == prohibit-password && $value == without-password ]] && value=prohibit-password
    if [[ $value != "$want" ]]; then
      gaia_error "effective sshd configuration differs from the wanted one (another file in sshd_config.d or sshd_config wins over the drop-in?)" \
        "option=$key" "expected=$want" "effective=${value:-?}"
      ok=1
    fi
  done
  want=$(gaia_ssh_allow_users | tr ' ' '\n' | sort | tr '\n' ' ')
  value=$(awk '$1 == "allowusers" { print $2 }' <<<"$effective" | sort | tr '\n' ' ')
  if [[ $value != "$want" ]]; then
    gaia_error "effective AllowUsers differs from the wanted one" "expected=${want% }" "effective=${value% }"
    ok=1
  fi
  return "$ok"
}

ssh__restore() {
  local real=$1 had=$2 previous=$3
  if [[ $had == 1 ]]; then
    printf '%s\n' "$previous" >"$real"
    gaia_warn "drop-in restored to its previous version" "file=$GAIA_SSH_DROPIN"
  else
    rm -f "$real"
    gaia_warn "drop-in removed" "file=$GAIA_SSH_DROPIN"
  fi
}

# Users with SSH keys that AllowUsers would leave out: they lose SSH access.
ssh__warn_excluded_users() {
  local allow f user
  allow=" $(gaia_ssh_allow_users) "
  [[ -n ${allow// /} ]] || return 0
  for f in "$(gaia_path /home)"/*/.ssh/authorized_keys; do
    [[ -f $f ]] || continue
    user=${f%/.ssh/authorized_keys}
    user=${user##*/}
    [[ $allow == *" $user "* ]] && continue
    [[ $(gaia_count_valid_keys "$f") -gt 0 ]] || continue
    gaia_warn "user has SSH keys but is not in AllowUsers: it will no longer log in over SSH (add it to GAIA_SSH_ALLOW_USERS if needed)" "user=$user"
  done
}

step_run() {
  gaia_require_admin
  local u=$GAIA_ADMIN_USER content real had=0 previous="" home n old_port

  local main
  main=$(gaia_path /etc/ssh/sshd_config)
  if [[ ! -f $main ]] && gaia_is_dry_run; then
    gaia_warn "dry-run: /etc/ssh/sshd_config does not exist yet (openssh-server is installed by the packages step)"
  elif ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main" 2>/dev/null; then
    gaia_fail "/etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf'; the drop-in would have no effect. Nothing was changed"
  fi

  # 1. Lock-out protection: the administrator needs a valid key before passwords/root go away.
  home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)
  n=0
  [[ -n $home ]] && n=$(gaia_count_valid_keys "$(gaia_path "$home/.ssh/authorized_keys")")
  if ((n > 0)); then
    gaia_info "lock-out protection ok: the administrator has a key to log in" "user=$u" "valid_keys=$n"
  else
    local -a GAIA_KEYS=()
    if gaia_is_dry_run && gaia_keys_collect && ((${#GAIA_KEYS[@]} > 0)); then
      gaia_warn "dry-run: the administrator has no key installed yet; counting the keys the admin-user step would install" "user=$u" "keys=${#GAIA_KEYS[@]}"
    else
      gaia_fail "REFUSED: user $u has no valid key in ~/.ssh/authorized_keys. Disabling passwords/root login now would lock you out; nothing was changed. Run the admin-user step with --ssh-key, --github-keys or GAIA_ADMIN_SSH_KEYS" "user=$u"
    fi
  fi
  ssh__warn_excluded_users

  content=$(ssh__content)
  real=$(gaia_path "$GAIA_SSH_DROPIN")
  if [[ -f $real ]]; then
    had=1
    previous=$(<"$real")
  fi
  old_port=$(ssh__effective port)
  old_port=${old_port:-22}

  if ((had)) && [[ $previous == "$content" ]]; then
    if ! gaia_is_dry_run; then
      ssh__check_effective || gaia_fail "the drop-in is correct, but another configuration wins; fix the file named above"
    fi
    gaia_info "ssh drop-in already correct" "file=$GAIA_SSH_DROPIN" "port=$GAIA_SSH_PORT"
    return 0
  fi

  # 5. New port with the firewall on: open it before applying.
  if [[ $old_port != "$GAIA_SSH_PORT" ]] && gaia_ufw_active; then
    if [[ $GAIA_SSH_RATE_LIMIT == 1 ]]; then gaia_ufw_ensure limit "$GAIA_SSH_PORT/tcp"; else gaia_ufw_ensure allow "$GAIA_SSH_PORT/tcp"; fi
  fi

  gaia_ensure_file "$GAIA_SSH_DROPIN" 0644 "$content"
  if gaia_is_dry_run; then
    gaia_info "[dry-run] would check with sshd -t, compare with sshd -T and reload ssh"
    return 0
  fi

  # 2. Syntax check.
  local out rc=0 line
  out=$(sshd -t 2>&1) || rc=$?
  if ((rc != 0)); then
    while IFS= read -r line; do
      [[ -n $line ]] && gaia_error "sshd -t: $line"
    done <<<"$out"
    ssh__restore "$real" "$had" "$previous"
    gaia_fail "sshd -t rejected the configuration; nothing was reloaded" "code=$rc"
  fi
  gaia_info "sshd -t accepted the configuration"

  # 3. Effective configuration.
  if ! ssh__check_effective; then
    ssh__restore "$real" "$had" "$previous"
    gaia_fail "effective configuration does not match; drop-in rolled back and nothing was reloaded"
  fi

  # 4. Reload without dropping sessions.
  local port_changed=0
  [[ $old_port != "$GAIA_SSH_PORT" ]] && port_changed=1
  if ((port_changed)) && systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    # Ubuntu 24.04+: ssh.socket listens on the port; the systemd generator reads Port from sshd_config.
    gaia_run systemctl daemon-reload
    gaia_run systemctl restart ssh.socket
  fi
  if systemctl is-active --quiet ssh.service 2>/dev/null; then
    gaia_run systemctl reload ssh.service
  elif ! systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    gaia_warn "ssh service is not active; the configuration applies when it starts"
  fi
  if ((port_changed)); then
    gaia_warn "SSH port changed: do NOT close this session; test 'ssh -p $GAIA_SSH_PORT $u@<server>' in another window" \
      "old_port=$old_port" "new_port=$GAIA_SSH_PORT"
  fi
  gaia_info "ssh hardened" "port=$GAIA_SSH_PORT" "root=$GAIA_SSH_PERMIT_ROOT_LOGIN" "password=$GAIA_SSH_PASSWORD_AUTH" \
    "allow_users=$(gaia_ssh_allow_users)" "modern_crypto=$GAIA_SSH_MODERN_CRYPTO"
}
