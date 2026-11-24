# shellcheck shell=bash
# gaia-description: administrator account (GAIA_ADMIN_USER) in the sudo group, with its public SSH keys

# shellcheck source=../keys.sh
source "$GAIA_HOME/lib/keys.sh"

# "type body" of an authorized_keys line (ignores leading options and the comment).
admin__identity() {
  local key
  key=$(gaia_key_from_line "$1") || return 1
  [[ $key =~ $GAIA_KEY_RE ]] && printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
}

admin__validate_sudoers() {
  visudo -cf "$1" >/dev/null
}

step_run() {
  gaia_require_admin
  local u=$GAIA_ADMIN_USER key home group
  local -a GAIA_KEYS=()
  gaia_keys_collect

  if id -u "$u" >/dev/null 2>&1; then
    gaia_info "user already exists" "user=$u"
    if gaia_user_in_group "$u" sudo; then
      gaia_info "user already in the sudo group" "user=$u"
    else
      gaia_run usermod -aG sudo "$u"
    fi
  else
    gaia_run useradd --create-home --shell "$GAIA_ADMIN_SHELL" --groups sudo --comment "Administrator (Gaia)" "$u"
  fi

  home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)
  home=${home:-/home/$u}
  group=$(id -gn "$u" 2>/dev/null || echo "$u")

  gaia_ensure_dir "$home/.ssh" 0700 "$u:$group"

  local file current="" new known=$'\n' line id
  file=$(gaia_path "$home/.ssh/authorized_keys")
  if [[ -f $file ]]; then
    current=$(<"$file")
    while IFS= read -r line; do
      known+="$(admin__identity "$line" || true)"$'\n'
    done <<<"$current"
  fi
  new=$current
  for key in "${GAIA_KEYS[@]}"; do
    [[ $key =~ $GAIA_KEY_RE ]] || continue
    local type=${BASH_REMATCH[1]} comment=${BASH_REMATCH[5]:-no-comment}
    id=$(admin__identity "$key")
    if [[ $known == *$'\n'"$id"$'\n'* ]]; then
      gaia_info "key already present" "type=$type" "comment=$comment"
    else
      gaia_info "key added" "type=$type" "comment=$comment"
      if [[ -n $new ]]; then new+=$'\n'; fi
      new+=$key
      known+="$id"$'\n'
    fi
  done
  if [[ -z ${new//[[:space:]]/} ]]; then
    gaia_fail "no public key for the administrator: use --ssh-key, --github-keys or GAIA_ADMIN_SSH_KEYS (nothing found to import from root either). Key-only SSH would lock you out"
  fi
  gaia_ensure_file "$home/.ssh/authorized_keys" 0600 "$new" 1
  gaia_ensure_owner "$home/.ssh/authorized_keys" "$u:$group"

  if [[ $GAIA_ADMIN_SUDO_NOPASSWD == 1 ]]; then
    gaia_ensure_file "/etc/sudoers.d/90-gaia-$u" 0440 \
      "# Managed by Gaia (admin-user step): passwordless sudo for the administrator (key-only login).
$u ALL=(ALL) NOPASSWD:ALL" 0 admin__validate_sudoers
  else
    local state
    state=$(passwd -S "$u" 2>/dev/null | awk '{ print $2 }' || true)
    if [[ $state == L || $state == NP || -z $state ]]; then
      gaia_warn "the user has no password: sudo will ask for a password that does not exist. Set one with 'passwd $u' (in this root session) or use GAIA_ADMIN_SUDO_NOPASSWD=1" "user=$u"
    fi
  fi
}
