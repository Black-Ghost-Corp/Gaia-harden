# shellcheck shell=bash
# lib/config.sh — loads gaia.conf, applies defaults and validates every value.
#
# Precedence: command line > gaia.conf > environment variable already set > default below.
# The defaults here are the same ones documented in gaia.conf.example (a test keeps both in sync).

gaia_config_defaults() {
  # Optional modules to install on top of the hardened base (space or comma separated).
  : "${GAIA_MODULES:=}"
  # Administrator account
  : "${GAIA_ADMIN_USER:=}"
  : "${GAIA_ADMIN_SSH_KEYS:=}"
  : "${GAIA_ADMIN_GITHUB_KEYS:=}"
  : "${GAIA_ADMIN_IMPORT_KEYS:=auto}"
  : "${GAIA_ADMIN_SHELL:=/bin/bash}"
  : "${GAIA_ADMIN_SUDO_NOPASSWD:=1}"
  # System
  : "${GAIA_HOSTNAME:=}"
  : "${GAIA_TIMEZONE:=UTC}"
  : "${GAIA_NTP_PACKAGE:=auto}"
  : "${GAIA_MIN_DISK_GB:=5}"
  : "${GAIA_REQUIRE_SYSTEMD:=1}"
  : "${GAIA_CHECK_INTERNET:=1}"
  : "${GAIA_APT_FULL_UPGRADE:=1}"
  : "${GAIA_APT_UPDATE_MAX_AGE:=3600}"
  : "${GAIA_EXTRA_PACKAGES:=}"
  : "${GAIA_SWAP_SIZE:=}"
  : "${GAIA_SWAP_FILE:=/swapfile}"
  : "${GAIA_SWAPPINESS:=10}"
  : "${GAIA_DIRS:=}"
  # SSH
  : "${GAIA_SSH_PORT:=22}"
  : "${GAIA_SSH_PERMIT_ROOT_LOGIN:=no}"
  : "${GAIA_SSH_PASSWORD_AUTH:=no}"
  : "${GAIA_SSH_ALLOW_USERS=@admin}"
  : "${GAIA_SSH_MODERN_CRYPTO:=1}"
  : "${GAIA_SSH_MAX_AUTH_TRIES:=3}"
  : "${GAIA_SSH_LOGIN_GRACE_TIME:=30}"
  : "${GAIA_SSH_CLIENT_ALIVE_INTERVAL:=300}"
  : "${GAIA_SSH_TCP_FORWARDING:=local}"
  : "${GAIA_SSH_AGENT_FORWARDING:=no}"
  : "${GAIA_SSH_DROPIN:=/etc/ssh/sshd_config.d/00-gaia.conf}"
  # Firewall and intrusion prevention
  : "${GAIA_FIREWALL_ALLOW:=}"
  : "${GAIA_SSH_RATE_LIMIT:=1}"
  : "${GAIA_FAIL2BAN_BANTIME:=1h}"
  : "${GAIA_FAIL2BAN_FINDTIME:=10m}"
  : "${GAIA_FAIL2BAN_MAXRETRY:=5}"
  : "${GAIA_FAIL2BAN_BACKEND:=systemd}"
  : "${GAIA_FAIL2BAN_IGNOREIP:=127.0.0.1/8 ::1}"
  # Exposed services
  : "${GAIA_DISABLE_UNUSED_SERVICES:=1}"
  : "${GAIA_DISABLE_SERVICES:=}"
  : "${GAIA_MTA_LOCAL_ONLY:=1}"
  # Kernel, logs and mandatory access control
  : "${GAIA_SYSCTL:=1}"
  : "${GAIA_SYSCTL_EXTRA:=}"
  : "${GAIA_JOURNALD:=1}"
  : "${GAIA_JOURNALD_MAX_USE:=500M}"
  : "${GAIA_APPARMOR:=1}"
  # Automatic updates
  : "${GAIA_AUTO_REBOOT:=0}"
  : "${GAIA_AUTO_REBOOT_TIME:=04:00}"
  # Security audit (Lynis) before and after
  : "${GAIA_AUDIT:=1}"
  # Module: docker
  : "${GAIA_DOCKER_LOG_MAX_SIZE:=10m}"
  : "${GAIA_DOCKER_LOG_MAX_FILE:=3}"
  : "${GAIA_DOCKER_DATA_ROOT:=}"
  : "${GAIA_DOCKER_ADD_ADMIN_TO_GROUP:=1}"
  : "${GAIA_DOCKER_UFW:=1}"
  : "${GAIA_DOCKER_PUBLISH:=}"
  : "${GAIA_DOCKER_LOCALHOST_ONLY:=0}"
  : "${GAIA_DOCKER_SMOKE_TEST:=1}"
  # Module: caddy
  : "${GAIA_CADDY_SITES:=}"
  : "${GAIA_CADDY_EMAIL:=}"
  : "${GAIA_CADDY_BLOCK_PATHS:=}"
  # Runtime
  : "${GAIA_EXTRA_STEPS_DIR:=$GAIA_HOME/steps.d}"
  : "${GAIA_LOG_DIR:=/var/log/gaia}"
  : "${GAIA_DEBUG:=0}"
}

# Command line overrides (filled by lib/runner.sh), applied on top of gaia.conf.
declare -gA GAIA__CLI=()

# Loads the file (if any), the command line overrides and the defaults.
# $1 = path; $2 = 1 if a missing file is an error.
gaia_config_load() {
  local file=$1 required=$2 key
  if [[ -f $file ]]; then
    local mode
    mode=$(stat -c %a "$file" 2>/dev/null || echo 600)
    # The file is sourced as root: write access for group/others is a risk.
    if (((8#$mode & 8#022) != 0)); then
      gaia_warn "configuration file is writable by other users; use chmod 600" "file=$file" "mode=$mode"
    fi
    # shellcheck source=/dev/null
    source "$file"
  elif [[ $required == 1 ]]; then
    gaia_die "configuration file not found: $file (copy gaia.conf.example to gaia.conf, or omit --config)"
  fi
  for key in "${!GAIA__CLI[@]}"; do
    printf -v "$key" '%s' "${GAIA__CLI[$key]}"
  done
  gaia_config_defaults
}

gaia__check() {
  local name=$1 regex=$2 hint=$3 value
  value=${!name}
  [[ $value =~ $regex ]] || gaia_die "invalid value for $name: '$value' ($hint)"
}

# Normalizes a list ("docker,caddy", "caddy docker") into GAIA_MODULES, space separated, in the
# order of $GAIA_AVAILABLE_MODULES. Unknown names exit with 2. $2 = where it came from.
gaia_modules_normalize() {
  local input=${1//,/ } origin=$2 m found
  local -A wanted=()
  for m in $input; do
    m=${m,,}
    case $m in
      none) continue ;;
      all) for found in $GAIA_AVAILABLE_MODULES; do wanted[$found]=1; done; continue ;;
    esac
    if [[ " $GAIA_AVAILABLE_MODULES " != *" $m "* ]]; then
      gaia_error "unknown module in $origin: '$m' (available: ${GAIA_AVAILABLE_MODULES:-none})"
      exit 2
    fi
    wanted[$m]=1
  done
  GAIA_MODULES=""
  for m in $GAIA_AVAILABLE_MODULES; do
    [[ -n ${wanted[$m]:-} ]] && GAIA_MODULES+="${GAIA_MODULES:+ }$m"
  done
  return 0
}

gaia_module_selected() { [[ " $GAIA_MODULES " == *" $1 "* ]]; }

gaia_config_validate() {
  local b
  for b in GAIA_ADMIN_SUDO_NOPASSWD GAIA_REQUIRE_SYSTEMD GAIA_CHECK_INTERNET GAIA_APT_FULL_UPGRADE \
    GAIA_SSH_MODERN_CRYPTO GAIA_SSH_RATE_LIMIT GAIA_DISABLE_UNUSED_SERVICES GAIA_MTA_LOCAL_ONLY GAIA_SYSCTL \
    GAIA_JOURNALD GAIA_APPARMOR GAIA_AUTO_REBOOT GAIA_AUDIT GAIA_DOCKER_ADD_ADMIN_TO_GROUP GAIA_DOCKER_UFW \
    GAIA_DOCKER_LOCALHOST_ONLY GAIA_DOCKER_SMOKE_TEST GAIA_DEBUG; do
    gaia__check "$b" '^[01]$' "use 0 or 1"
  done
  gaia__check GAIA_ADMIN_IMPORT_KEYS '^(auto|0|1)$' "auto, 0 or 1"
  gaia__check GAIA_SSH_PORT '^[0-9]{1,5}$' "port between 1 and 65535"
  ((GAIA_SSH_PORT >= 1 && GAIA_SSH_PORT <= 65535)) || gaia_die "invalid value for GAIA_SSH_PORT: '$GAIA_SSH_PORT' (port between 1 and 65535)"
  gaia__check GAIA_SSH_PERMIT_ROOT_LOGIN '^(no|yes|prohibit-password)$' "no, prohibit-password or yes"
  gaia__check GAIA_SSH_PASSWORD_AUTH '^(no|yes)$' "no or yes"
  gaia__check GAIA_SSH_DROPIN '^/etc/ssh/sshd_config\.d/[A-Za-z0-9._-]+\.conf$' ".conf file inside /etc/ssh/sshd_config.d"
  gaia__check GAIA_SSH_ALLOW_USERS '^([@a-z_][a-z0-9_.@*?-]*( [@a-z_][a-z0-9_.@*?-]*)*)?$' "user names (or @admin) separated by spaces, empty to disable"
  gaia__check GAIA_SSH_MAX_AUTH_TRIES '^[1-9][0-9]?$' "number between 1 and 99"
  gaia__check GAIA_SSH_LOGIN_GRACE_TIME '^[0-9]+[smh]?$' "e.g. 30 or 1m"
  gaia__check GAIA_SSH_CLIENT_ALIVE_INTERVAL '^[0-9]+$' "seconds (0 disables)"
  gaia__check GAIA_SSH_TCP_FORWARDING '^(yes|no|local|remote|all)$' "no, local, remote, yes or all"
  gaia__check GAIA_SSH_AGENT_FORWARDING '^(yes|no)$' "yes or no"
  gaia__check GAIA_MIN_DISK_GB '^[0-9]+$' "whole number of GB"
  gaia__check GAIA_APT_UPDATE_MAX_AGE '^[0-9]+$' "seconds"
  gaia__check GAIA_EXTRA_PACKAGES '^([a-z0-9][a-z0-9+.:-]*( +[a-z0-9][a-z0-9+.:-]*)*)?$' "package names separated by spaces"
  gaia__check GAIA_NTP_PACKAGE '^(auto|chrony|systemd-timesyncd)$' "auto, chrony or systemd-timesyncd"
  gaia__check GAIA_FAIL2BAN_MAXRETRY '^[0-9]+$' "whole number"
  gaia__check GAIA_FAIL2BAN_BANTIME '^-?[0-9]+[smhdw]?$' "e.g. 1h, 600, -1 (permanent)"
  gaia__check GAIA_FAIL2BAN_FINDTIME '^[0-9]+[smhdw]?$' "e.g. 10m"
  gaia__check GAIA_FAIL2BAN_BACKEND '^(systemd|auto|pyinotify|polling)$' "systemd, auto, pyinotify or polling"
  gaia__check GAIA_FAIL2BAN_IGNOREIP '^[0-9A-Fa-f.:/ ]*$' "IPs or CIDRs separated by spaces"
  gaia__check GAIA_AUTO_REBOOT_TIME '^([01][0-9]|2[0-3]):[0-5][0-9]$' "HH:MM"
  gaia__check GAIA_DISABLE_SERVICES '^([A-Za-z0-9@._-]+( +[A-Za-z0-9@._-]+)*)?$' "systemd unit names separated by spaces"
  gaia__check GAIA_JOURNALD_MAX_USE '^[0-9]+[KMG]$' "e.g. 500M or 1G"
  gaia__check GAIA_SWAP_SIZE '^([1-9][0-9]*[MG])?$' "e.g. 1G or 512M, empty to skip"
  gaia__check GAIA_SWAP_FILE '^/[A-Za-z0-9._/-]+$' "absolute path"
  gaia__check GAIA_SWAPPINESS '^([0-9]|[1-9][0-9]|100)$' "0 to 100"
  gaia__check GAIA_HOSTNAME '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*)?$' "lowercase host name or FQDN, e.g. web-01 or web-01.example.com"
  ((${#GAIA_HOSTNAME} <= 253)) || gaia_die "invalid value for GAIA_HOSTNAME: longer than 253 characters"
  gaia__check GAIA_LOG_DIR '^/[^[:space:]]*$' "absolute path"
  gaia__check GAIA_TIMEZONE '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$' "e.g. UTC or America/New_York"
  gaia__check GAIA_ADMIN_SHELL '^/[A-Za-z0-9._/-]+$' "absolute path, e.g. /bin/bash"
  if [[ -n $GAIA_ADMIN_USER ]]; then
    gaia__check GAIA_ADMIN_USER '^[a-z_][a-z0-9_-]{0,31}$' "Linux user name"
    [[ $GAIA_ADMIN_USER != root ]] || gaia_die "GAIA_ADMIN_USER cannot be root"
  fi
  local u
  for u in $GAIA_ADMIN_GITHUB_KEYS; do
    [[ $u =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || gaia_die "invalid value for GAIA_ADMIN_GITHUB_KEYS: '$u' (GitHub user names separated by spaces)"
  done
  local rule
  for rule in $GAIA_FIREWALL_ALLOW $GAIA_DOCKER_PUBLISH; do
    [[ $rule =~ ^[0-9]{1,5}(:[0-9]{1,5})?(/(tcp|udp))?$ ]] ||
      gaia_die "invalid firewall rule: '$rule' in GAIA_FIREWALL_ALLOW or GAIA_DOCKER_PUBLISH (e.g. 80/tcp 443/tcp 60000:61000/udp)"
    [[ $rule != *:* || $rule == */* ]] ||
      gaia_die "invalid firewall rule: '$rule' (a port range needs a protocol, e.g. 60000:61000/udp)"
  done
  local kv
  for kv in $GAIA_SYSCTL_EXTRA; do
    [[ $kv =~ ^[a-z0-9_.-]+(/[a-z0-9_.-]+)*=[A-Za-z0-9_.:,-]+$ ]] ||
      gaia_die "invalid value in GAIA_SYSCTL_EXTRA: '$kv' (key=value separated by spaces, e.g. vm.max_map_count=262144)"
  done
  local entry
  for entry in $GAIA_DIRS; do
    [[ $entry =~ ^/[^:]+:[^:]+:[^:]+:[0-7]{3,4}$ ]] ||
      gaia_die "invalid entry in GAIA_DIRS: '$entry' (format: /path:owner:group:mode, e.g. /srv/apps:@admin:@admin:0755)"
  done
  gaia__validate_docker
  gaia__validate_caddy
}

gaia__validate_docker() {
  gaia__check GAIA_DOCKER_LOG_MAX_SIZE '^[0-9]+[kmg]$' "e.g. 10m"
  gaia__check GAIA_DOCKER_LOG_MAX_FILE '^[0-9]+$' "whole number"
  gaia__check GAIA_DOCKER_DATA_ROOT '^(/[^[:space:]]*)?$' "absolute path or empty"
}

# Each site is "domain=upstream" (upstream host:port, usually 127.0.0.1:<published port>).
gaia__validate_caddy() {
  local s domain upstream seen=" " p
  gaia__check GAIA_CADDY_EMAIL '^([^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+)?$' "ACME account e-mail or empty"
  for s in $GAIA_CADDY_SITES; do
    domain=${s%%=*}
    upstream=${s#*=}
    [[ $s == *=* && $domain =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ && $upstream =~ ^(h2c://)?[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] ||
      gaia_die "invalid value in GAIA_CADDY_SITES: '$s' (domain=host:port or domain=h2c://host:port, e.g. app.example.com=127.0.0.1:8080)"
    [[ $seen != *" $domain "* ]] || gaia_die "duplicate domain in GAIA_CADDY_SITES: '$domain'"
    seen+="$domain "
  done
  for p in $GAIA_CADDY_BLOCK_PATHS; do
    [[ $p =~ ^/[A-Za-z0-9/_.*-]*$ ]] ||
      gaia_die "invalid value in GAIA_CADDY_BLOCK_PATHS: '$p' (paths starting with /, e.g. /internal/*)"
  done
}

# Steps that need the administrator account.
gaia_require_admin() {
  [[ -n $GAIA_ADMIN_USER ]] || gaia_fail "GAIA_ADMIN_USER is required for this step (set it in gaia.conf or use --admin-user)"
}

# GAIA_SSH_ALLOW_USERS with @admin resolved.
gaia_ssh_allow_users() {
  local u out=""
  for u in $GAIA_SSH_ALLOW_USERS; do
    [[ $u == @admin ]] && u=$GAIA_ADMIN_USER
    [[ -n $u && " $out " != *" $u "* ]] && out+="${out:+ }$u"
  done
  printf '%s' "$out"
}

# Configuration summary for the log (no secrets: keys become counts).
gaia_config_log() {
  local n=0 l
  while IFS= read -r l; do [[ -n ${l//[[:space:]]/} ]] && n=$((n + 1)); done <<<"$GAIA_ADMIN_SSH_KEYS"
  gaia_info "configuration" "admin=${GAIA_ADMIN_USER:-<empty>}" "ssh_keys=$n" "github_keys=${GAIA_ADMIN_GITHUB_KEYS:-none}" \
    "ssh_port=$GAIA_SSH_PORT" "timezone=$GAIA_TIMEZONE" "firewall_allow=$GAIA_FIREWALL_ALLOW" \
    "modules=${GAIA_MODULES:-none}" "audit=$GAIA_AUDIT" "extra_steps=$GAIA_EXTRA_STEPS_DIR"
}
