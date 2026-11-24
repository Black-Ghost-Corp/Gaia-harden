# shellcheck shell=bash
# gaia-description: checks root, system, free disk, network access and systemd; records what is listening (changes nothing)
#
# Root and system/architecture are already enforced by the runner before any step (even with --only
# and --dry-run); this step holds the slower checks and the initial listening sockets snapshot.

# apt mirrors: URIs from sources.list (one-line format) and from *.sources (deb822).
preflight__mirrors() {
  local f line
  for f in "$(gaia_path /etc/apt/sources.list)" "$(gaia_path /etc/apt/sources.list.d)"/*.list; do
    [[ -f $f ]] || continue
    while read -r line; do
      [[ $line =~ ^deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?([a-z]+://[^[:space:]]+) ]] &&
        printf '%s\n' "${BASH_REMATCH[3]}"
    done <"$f"
  done
  for f in "$(gaia_path /etc/apt/sources.list.d)"/*.sources; do
    [[ -f $f ]] || continue
    sed -n 's/^URIs:[[:space:]]*//p' "$f" | tr ' ' '\n'
  done
}

# HTTP status of the target (any answer proves connectivity) or 000. Without curl (minimal Debian),
# only tests the TCP connection with bash's /dev/tcp and prints "tcp".
preflight__probe() {
  local url=$1 code host port
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -sS -o /dev/null --max-time 15 -w '%{http_code}' "$url" 2>/dev/null) || code=000
    printf '%s' "${code:-000}"
    return 0
  fi
  host=${url#*://}
  host=${host%%/*}
  port=80
  [[ $url == https://* ]] && port=443
  if timeout 15 bash -c ": >/dev/tcp/$host/$port" 2>/dev/null; then printf 'tcp'; else printf '000'; fi
}

preflight__disk() {
  local target=$1 real free_kb min_kb
  real=$(gaia_path "$target")
  # Directory not created yet (e.g. a new Docker data-root): measure the first existing parent.
  while [[ ! -d $real && $real != / && -n $real ]]; do real=$(dirname "$real"); done
  free_kb=$(df -Pk "${real:-/}" | awk 'NR == 2 { print $4 }')
  min_kb=$((GAIA_MIN_DISK_GB * 1024 * 1024))
  if ((free_kb < min_kb)); then
    gaia_error "not enough free disk space" "path=$target" "free_gb=$((free_kb / 1024 / 1024))" "min_gb=$GAIA_MIN_DISK_GB"
    return 1
  fi
  gaia_info "free disk space ok" "path=$target" "free_gb=$((free_kb / 1024 / 1024))" "min_gb=$GAIA_MIN_DISK_GB"
}

step_run() {
  local problems=0
  gaia_info "running as root" "uid=$(id -u)"
  gaia_info "system detected" "id=$GAIA_OS_ID" "version=$GAIA_OS_VERSION" "codename=$GAIA_OS_CODENAME" "arch=$GAIA_ARCH"
  gaia_in_container && gaia_warn "running inside a container: kernel settings, swap and AppArmor belong to the host and will be skipped"

  preflight__disk / || problems=$((problems + 1))
  if gaia_module_selected docker && [[ -n $GAIA_DOCKER_DATA_ROOT ]]; then
    preflight__disk "$GAIA_DOCKER_DATA_ROOT" || problems=$((problems + 1))
  fi

  if [[ -d $(gaia_path /run/systemd/system) ]]; then
    gaia_info "systemd present"
  elif [[ $GAIA_REQUIRE_SYSTEMD == 1 ]]; then
    gaia_error "systemd is not running (/run/systemd/system missing); Gaia needs it to manage services"
    problems=$((problems + 1))
  else
    gaia_warn "systemd is not running; steps that manage services may fail (GAIA_REQUIRE_SYSTEMD=0)"
  fi

  if [[ $GAIA_CHECK_INTERNET == 1 ]]; then
    local -a targets
    local url host code
    local -A seen=()
    mapfile -t targets < <(preflight__mirrors)
    ((${#targets[@]})) || gaia_warn "no apt mirror found in /etc/apt/sources.list*"
    gaia_module_selected docker && targets+=("https://download.docker.com/linux/$GAIA_OS_ID/gpg")
    gaia_module_selected caddy && targets+=("https://dl.cloudsmith.io/public/caddy/stable/gpg.key")
    [[ -n $GAIA_ADMIN_GITHUB_KEYS ]] && targets+=("https://github.com/")
    for url in "${targets[@]}"; do
      host=${url#*://}
      host=${host%%/*}
      [[ -z ${seen[$host]:-} ]] || continue
      seen[$host]=1
      code=$(preflight__probe "$url")
      if [[ $code == 000 ]]; then
        gaia_error "required destination unreachable" "url=$url"
        problems=$((problems + 1))
      else
        gaia_info "reachable" "url=$url" "http=$code"
      fi
    done
  else
    gaia_warn "network check disabled (GAIA_CHECK_INTERNET=0)"
  fi

  # Listening sockets before any change (compared at the end by the summary step).
  if [[ -n ${GAIA_RUN_DIR:-} ]] && gaia_ports_snapshot >"$GAIA_RUN_DIR/ports-before"; then
    gaia_ports_report "$GAIA_RUN_DIR/ports-before" before
  else
    gaia_info "listening sockets not recorded before the run ('ss' from iproute2 is not installed yet)"
  fi

  ((problems == 0)) || gaia_fail "preflight found problems; fix them before continuing" "problems=$problems"
  gaia_info "prerequisites ok"
}
