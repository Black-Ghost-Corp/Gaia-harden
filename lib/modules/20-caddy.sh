# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: Caddy reverse proxy with automatic HTTPS (Let's Encrypt) for the sites in GAIA_CADDY_SITES
#
# Installs Caddy from its OFFICIAL repository (key checked by fingerprint) as a systemd service on
# the host. It listens on 80 and 443, obtains and renews a certificate for each domain and forwards
# to the application, which stays bound to 127.0.0.1 (e.g. "127.0.0.1:8080:8080" in compose).
# Because it runs on the host, Caddy goes through ufw normally: the module opens 80/tcp and 443/tcp.
#
# What this module guarantees, in order (each part acts only if needed):
#   1. repository key and apt source, caddy package installed;
#   2. /etc/caddy/sites.d (hand-written sites, *.caddy) and /etc/caddy/Caddyfile generated from
#      GAIA_CADDY_SITES, checked with "caddy validate" BEFORE replacing the current one;
#   3. 80/tcp and 443/tcp allowed in ufw;
#   4. service enabled; reloaded (no dropped connections) when the Caddyfile changed.

GAIA_CADDY_FPR=65760C51EDEA2017CEA2CA15155B6D79CA56EA34 # "Caddy Web Server <contact@caddyserver.com>"
GAIA_CADDY_KEYRING=/etc/apt/keyrings/caddy.asc
GAIA_CADDY_LIST=/etc/apt/sources.list.d/caddy-stable.list
GAIA_CADDY_FILE=/etc/caddy/Caddyfile
GAIA_CADDY_SITES_DIR=/etc/caddy/sites.d
GAIA_CADDY_KEY_URL=https://dl.cloudsmith.io/public/caddy/stable/gpg.key

# Caddyfile from GAIA_CADDY_SITES ("domain=upstream" separated by spaces):
#   - snippet gaia_blocks in EVERY site: paths in GAIA_CADDY_BLOCK_PATHS answer 403 (e.g. internal
#     endpoints that must never be reachable from the internet);
#   - security headers (HSTS, nosniff, referrer policy) and no "Server" header;
#   - reverse_proxy with flush_interval -1: server-sent events and streaming without buffering;
#   - upstream h2c://host:port for gRPC without TLS behind the proxy.
caddy__caddyfile() {
  local s p
  printf '%s\n' "# Managed by Gaia (caddy module). Do not edit: the next run restores this file."
  printf '%s\n' "# Hand-written sites: one *.caddy file in $GAIA_CADDY_SITES_DIR (imported at the end);"
  printf '%s\n' "# add \"import gaia_blocks\" and \"import gaia_headers\" to them too."
  if [[ -n $GAIA_CADDY_EMAIL ]]; then
    printf '\n{\n\temail %s\n}\n' "$GAIA_CADDY_EMAIL"
  fi
  printf '\n# Paths that never reach the internet (GAIA_CADDY_BLOCK_PATHS).\n(gaia_blocks) {\n'
  if [[ -n $GAIA_CADDY_BLOCK_PATHS ]]; then
    printf '\t@gaia_blocked path'
    for p in $GAIA_CADDY_BLOCK_PATHS; do printf ' %s' "$p"; done
    printf '\n\trespond @gaia_blocked 403\n'
  fi
  printf '}\n'
  printf '\n(gaia_headers) {\n\theader {\n\t\tStrict-Transport-Security "max-age=31536000"\n\t\tX-Content-Type-Options "nosniff"\n\t\tReferrer-Policy "strict-origin-when-cross-origin"\n\t\t-Server\n\t}\n}\n'
  for s in $GAIA_CADDY_SITES; do
    printf '\n%s {\n\timport gaia_blocks\n\timport gaia_headers\n\treverse_proxy %s {\n\t\tflush_interval -1\n\t}\n}\n' \
      "${s%%=*}" "${s#*=}"
  done
  printf '\nimport %s/*.caddy\n' "$GAIA_CADDY_SITES_DIR"
}

# Validator for gaia_ensure_file: receives the new (temporary) file before it is swapped in.
caddy__validate() {
  local out
  if ! out=$(caddy validate --adapter caddyfile --config "$1" 2>&1); then
    gaia_error "caddy validate rejected the generated Caddyfile: ${out##*$'\n'}"
    return 1
  fi
}

step_run() {
  [[ -n $GAIA_CADDY_SITES ]] ||
    gaia_warn "GAIA_CADDY_SITES is empty: Caddy starts only with the sites in $GAIA_CADDY_SITES_DIR (if any)"

  gaia_ensure_repo_key "$GAIA_CADDY_KEY_URL" "$GAIA_CADDY_KEYRING" "$GAIA_CADDY_FPR" Caddy
  gaia_ensure_file "$GAIA_CADDY_LIST" 0644 \
    "deb [signed-by=$GAIA_CADDY_KEYRING] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main"
  local list_changed=$GAIA_CHANGED

  if gaia_package_installed caddy; then
    if ((list_changed)); then gaia_apt_update force; fi
    gaia_info "caddy package already installed"
  else
    gaia_apt_update force
    gaia_run apt-get "${GAIA_APT_OPTS[@]}" install caddy
  fi

  gaia_ensure_dir "$GAIA_CADDY_SITES_DIR" 0755
  gaia_ensure_file "$GAIA_CADDY_FILE" 0644 "$(caddy__caddyfile)" 0 caddy__validate ||
    gaia_fail "invalid Caddyfile; the current one was kept" "file=$GAIA_CADDY_FILE"
  local caddyfile_changed=$GAIA_CHANGED

  if command -v ufw >/dev/null 2>&1; then
    gaia_ufw_ensure allow 80/tcp
    gaia_ufw_ensure allow 443/tcp
  else
    gaia_warn "ufw not installed: 80/tcp and 443/tcp were not opened here (run the firewall step)"
  fi

  if systemctl is-enabled --quiet caddy 2>/dev/null && systemctl is-active --quiet caddy 2>/dev/null; then
    if ((caddyfile_changed)); then
      gaia_run systemctl reload caddy
    else
      gaia_info "caddy service already enabled and running"
    fi
  else
    gaia_run systemctl enable --now caddy
  fi

  if [[ -n $GAIA_CADDY_BLOCK_PATHS ]]; then
    gaia_info "paths blocked (403) on every site" "paths=$GAIA_CADDY_BLOCK_PATHS"
  fi
  local s
  for s in $GAIA_CADDY_SITES; do
    gaia_info "site behind the proxy" "domain=${s%%=*}" "upstream=${s#*=}"
  done
  if [[ -n $GAIA_CADDY_SITES ]]; then
    gaia_warn "certificates are issued only when each domain's DNS points to this server and ports 80/443 are also open in the provider's firewall; follow with: journalctl -u caddy -f"
  fi
}
