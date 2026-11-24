# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# lib/keys.sh — where the administrator's public keys come from. Sourced by the admin-user and ssh
# steps. Sources, in order:
#   1. GAIA_ADMIN_SSH_KEYS / --ssh-key  (literal keys, one per line; an invalid line is an error)
#   2. GAIA_ADMIN_GITHUB_KEYS / --github-keys  (https://github.com/<user>.keys)
#   3. existing keys on the server (GAIA_ADMIN_IMPORT_KEYS): root's authorized_keys and the sudo
#      user's, which is how most VPS providers deliver the key you chose when creating the server.
#      "auto" imports only when 1 and 2 are empty.

# Fills the GAIA_KEYS array with every collected key ("type body comment"). Fails the step on a
# private key or an invalid literal key; never logs key material.
gaia_keys_collect() {
  local line n=0 user body file home key
  GAIA_KEYS=()
  if [[ $GAIA_ADMIN_SSH_KEYS == *"PRIVATE KEY"* ]]; then
    gaia_fail "GAIA_ADMIN_SSH_KEYS holds a private key; use only the PUBLIC key (.pub file). Nothing was installed and the content was not logged"
  fi
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -n ${line//[[:space:]]/} ]] || continue
    [[ $line =~ ^[[:space:]]*# ]] && continue
    n=$((n + 1))
    [[ $line =~ $GAIA_KEY_RE ]] ||
      gaia_fail "invalid public key in GAIA_ADMIN_SSH_KEYS (line $n); expected format: 'ssh-ed25519 AAAA... comment'. Nothing was installed"
    GAIA_KEYS+=("$line")
  done <<<"$GAIA_ADMIN_SSH_KEYS"

  for user in $GAIA_ADMIN_GITHUB_KEYS; do
    body=$(curl -fsSL --max-time 30 "https://github.com/$user.keys" 2>/dev/null) ||
      gaia_fail "could not download the public keys of GitHub user '$user' (https://github.com/$user.keys)"
    local found=0
    while IFS= read -r line; do
      line=${line%$'\r'}
      [[ $line =~ $GAIA_KEY_RE ]] || continue
      GAIA_KEYS+=("${BASH_REMATCH[1]} ${BASH_REMATCH[3]} github:$user")
      found=1
    done <<<"$body"
    ((found)) || gaia_fail "GitHub user '$user' has no public SSH keys"
  done

  if [[ $GAIA_ADMIN_IMPORT_KEYS == 1 || ($GAIA_ADMIN_IMPORT_KEYS == auto && -z ${GAIA_ADMIN_SSH_KEYS//[[:space:]]/} && -z $GAIA_ADMIN_GITHUB_KEYS) ]]; then
    local -a files=(/root/.ssh/authorized_keys)
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root && $SUDO_USER != "$GAIA_ADMIN_USER" ]]; then
      home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
      [[ -n $home ]] && files+=("$home/.ssh/authorized_keys")
    fi
    for file in "${files[@]}"; do
      [[ -f $(gaia_path "$file") ]] || continue
      while IFS= read -r line; do
        if key=$(gaia_key_from_line "$line"); then GAIA_KEYS+=("$key"); fi
      done <"$(gaia_path "$file")"
    done
  fi
  return 0
}
