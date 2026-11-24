# shellcheck shell=bash
# lib/os.sh — distribution, version and architecture detection; NTP package per distribution.

GAIA_SUPPORTED_OS="Ubuntu 22.04/24.04/26.04, Debian 12/13 (amd64 or arm64)"

# Reads /etc/os-release without executing it (it is KEY=value, but we do not trust it as code).
gaia_detect_os() {
  local file line key value
  file=$(gaia_path /etc/os-release)
  [[ -r $file ]] || gaia_die "cannot read /etc/os-release; unsupported system ($GAIA_SUPPORTED_OS)"
  GAIA_OS_ID="" GAIA_OS_VERSION="" GAIA_OS_CODENAME="" GAIA_OS_NAME=""
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value#[\"\']}
    value=${value%[\"\']}
    case $key in
      ID) GAIA_OS_ID=$value ;;
      VERSION_ID) GAIA_OS_VERSION=$value ;;
      VERSION_CODENAME) GAIA_OS_CODENAME=$value ;;
      PRETTY_NAME) GAIA_OS_NAME=$value ;;
    esac
  done <"$file"
  GAIA_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  export GAIA_OS_ID GAIA_OS_VERSION GAIA_OS_CODENAME GAIA_OS_NAME GAIA_ARCH
}

gaia_validate_os() {
  case "$GAIA_OS_ID:$GAIA_OS_VERSION" in
    ubuntu:22.04 | ubuntu:24.04 | ubuntu:26.04 | debian:12 | debian:13) ;;
    *) gaia_die "unsupported system: ${GAIA_OS_NAME:-unknown} (id=$GAIA_OS_ID version=$GAIA_OS_VERSION). Supported: $GAIA_SUPPORTED_OS" ;;
  esac
  case $GAIA_ARCH in
    amd64 | arm64) ;;
    *) gaia_die "unsupported architecture: $GAIA_ARCH. Supported: $GAIA_SUPPORTED_OS" ;;
  esac
  [[ -n $GAIA_OS_CODENAME ]] || gaia_die "VERSION_CODENAME missing from /etc/os-release"
}

# Time synchronization package (each distribution's default):
# - Debian: chrony (minimal servers do not always ship timesyncd; chrony is recommended for servers);
# - Ubuntu 26.04: chrony (Ubuntu replaced systemd-timesyncd with chrony starting with 25.10);
# - Ubuntu 22.04/24.04: systemd-timesyncd, already installed.
gaia_ntp_package() {
  if [[ $GAIA_NTP_PACKAGE != auto ]]; then
    printf '%s' "$GAIA_NTP_PACKAGE"
  elif [[ $GAIA_OS_ID == debian || $GAIA_OS_ID:$GAIA_OS_VERSION == ubuntu:26.04 ]]; then
    printf 'chrony'
  else
    printf 'systemd-timesyncd'
  fi
}
