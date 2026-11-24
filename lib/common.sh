# shellcheck shell=bash
# lib/common.sh — logging, secret masking, dry-run aware execution and idempotent file writes.
#
# Loaded by bootstrap.sh and by custom steps (steps.d/):
#
#   source "$GAIA_LIB_DIR/common.sh"
#   gaia_step_mode
#
# Contract with the runner (lib/runner.sh): a step that changes something calls gaia_run,
# gaia_ensure_file/dir/owner (which mark the step as changed) or gaia_mark_changed; a step that does
# not apply calls gaia_skip; a failure is any non-zero exit.

GAIA_ROOT=${GAIA_ROOT:-}
GAIA_STEP=${GAIA_STEP:-main}
GAIA_DRY_RUN=${GAIA_DRY_RUN:-0}
GAIA_DEBUG=${GAIA_DEBUG:-0}

# Real path of a system file. Tests point GAIA_ROOT at a fake root; on a server it is empty.
gaia_path() { printf '%s%s' "$GAIA_ROOT" "$1"; }

# ---------------------------------------------------------------------------------------------
# Secret masking. Result in REPLY (avoids a subshell per log line).
# ---------------------------------------------------------------------------------------------
GAIA__SECRET_RE='(password|secret|token|api_?key|signing_?key|private_?key|credential)'

gaia__is_secret_key() {
  local re="${GAIA__SECRET_RE}"
  shopt -s nocasematch
  if [[ $1 =~ $re ]]; then shopt -u nocasematch; return 0; fi
  shopt -u nocasematch
  return 1
}

gaia__redact() {
  local s=$1
  if [[ $s == *"PRIVATE KEY"* ]]; then
    REPLY='[REDACTED: private key material]'
    return
  fi
  # SECRET_NAME=value inside free text (only with "=" attached, so plain sentences are untouched).
  local re="(${GAIA__SECRET_RE}[A-Za-z0-9_]*=)([^*[:space:]][^[:space:]]*)"
  shopt -s nocasematch
  while [[ $s =~ $re ]]; do
    s=${s/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]}***"}
  done
  shopt -u nocasematch
  REPLY=$s
}

gaia__format_kv() {
  local kv=$1 key value
  if [[ $kv != *=* ]]; then
    gaia__redact "$kv"
    return
  fi
  key=${kv%%=*}
  value=${kv#*=}
  if gaia__is_secret_key "$key"; then
    value='***'
  else
    gaia__redact "$value"
    value=$REPLY
  fi
  if [[ -z $value || $value =~ [[:space:]] ]]; then
    REPLY="$key=\"$value\""
  else
    REPLY="$key=$value"
  fi
}

# ---------------------------------------------------------------------------------------------
# Logging: [gaia][level][step=<step>] message key=value...
# Screen: info/warn/error always, debug only with GAIA_DEBUG=1. File: everything, timestamped.
# ---------------------------------------------------------------------------------------------
gaia_log() {
  local level=$1 msg=$2 line kv ts
  shift 2
  gaia__redact "$msg"
  line="[gaia][$level][step=$GAIA_STEP] $REPLY"
  for kv in "$@"; do
    gaia__format_kv "$kv"
    line+=" $REPLY"
  done
  if [[ $level != debug || $GAIA_DEBUG == 1 ]]; then
    printf '%s\n' "$line"
  fi
  if [[ -n ${GAIA_LOG_FILE:-} && -w ${GAIA_LOG_FILE:-} ]]; then
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    printf '%s %s\n' "$ts" "$line" >>"$GAIA_LOG_FILE"
  fi
}

gaia_info() { gaia_log info "$@"; }
gaia_warn() { gaia_log warn "$@"; }
gaia_error() { gaia_log error "$@"; }
gaia_debug() { gaia_log debug "$@"; }

# Usage or environment error outside a step: log and exit.
gaia_die() {
  gaia_error "$@"
  exit 1
}

# Controlled step failure (does not fire the error trap).
gaia_fail() {
  gaia_error "$@"
  exit 1
}

# ---------------------------------------------------------------------------------------------
# Step mode: strict shell + a trap that reports step, file, line and the failing command.
# ---------------------------------------------------------------------------------------------
gaia__on_error() {
  local code=$1 line=$2 file=$3 command=$4
  gaia_error "command failed" "file=${file#"$GAIA_HOME/"}" "line=$line" "code=$code" "command=$command"
}

gaia_step_mode() {
  set -Eeuo pipefail
  trap 'gaia__on_error "$?" "$LINENO" "${BASH_SOURCE[0]:-?}" "$BASH_COMMAND"' ERR
}

# ---------------------------------------------------------------------------------------------
# Step result markers (read by the runner after the step finishes).
# ---------------------------------------------------------------------------------------------
gaia_mark_changed() {
  if [[ -n ${GAIA_RUN_DIR:-} ]]; then : >"$GAIA_RUN_DIR/changed"; fi
}

gaia_skip() {
  gaia_info "step skipped" "reason=$1"
  if [[ -n ${GAIA_RUN_DIR:-} ]]; then printf '%s\n' "$1" >"$GAIA_RUN_DIR/skipped"; fi
  exit 0
}

gaia_is_dry_run() { [[ $GAIA_DRY_RUN == 1 ]]; }

# Printable command line (arguments with spaces quoted, GAIA_ROOT stripped from paths).
gaia__command_text() {
  local a text=""
  for a in "$@"; do
    [[ -n $GAIA_ROOT ]] && a=${a//"$GAIA_ROOT"/}
    if [[ -z $a || $a =~ [[:space:]] ]]; then text+=" '$a'"; else text+=" $a"; fi
  done
  REPLY=${text# }
}

# Runs a command that CHANGES the system. In dry-run it only says what it would do.
# The command output goes to the log as debug; on failure the last lines are shown as errors.
gaia_run() {
  gaia__command_text "$@"
  local text=$REPLY
  gaia_mark_changed
  if gaia_is_dry_run; then
    gaia_info "[dry-run] would run: $text"
    return 0
  fi
  gaia_info "running: $text"
  local line rc=0
  local -a last=()
  while IFS= read -r line; do
    if [[ $line == __GAIA_RC=* ]]; then
      rc=${line#__GAIA_RC=}
      continue
    fi
    gaia_debug "$line"
    last+=("$line")
    ((${#last[@]} <= 15)) || last=("${last[@]:1}")
  done < <(
    rc=0
    "$@" 2>&1 </dev/null || rc=$?
    printf '\n__GAIA_RC=%s\n' "$rc"
  )
  if ((rc != 0)); then
    for line in "${last[@]}"; do
      [[ -n $line ]] && gaia_error "output: $line"
    done
    gaia_error "command returned an error" "code=$rc" "command=$text"
    return "$rc"
  fi
}

# ---------------------------------------------------------------------------------------------
# Idempotent writes. After each call, GAIA_CHANGED=1 if something changed (or would, in dry-run).
# ---------------------------------------------------------------------------------------------
GAIA_CHANGED=0

# gaia_ensure_file <path> <mode> <content> [sensitive=0|1] [validator]
#   sensitive=1: never show the diff (e.g. authorized_keys).
#   validator:   function called with the temporary file before it is installed (e.g. visudo -cf).
gaia_ensure_file() {
  local target=$1 mode=$2 content=$3 sensitive=${4:-0} validator=${5:-}
  local real current="" exists=0 current_mode=""
  real=$(gaia_path "$target")
  GAIA_CHANGED=0
  if [[ -f $real ]]; then
    exists=1
    current=$(<"$real")
    current_mode=$(stat -c %a "$real")
  fi
  if ((exists)) && [[ $current == "$content" ]]; then
    if [[ $current_mode != "${mode#0}" ]]; then
      GAIA_CHANGED=1
      gaia_run chmod "$mode" "$real"
    else
      gaia_debug "file already correct" "file=$target"
    fi
    return 0
  fi
  GAIA_CHANGED=1
  gaia_mark_changed
  local action=create
  ((exists)) && action=update
  if gaia_is_dry_run; then
    gaia_info "[dry-run] would $action file" "file=$target" "mode=$mode"
    if [[ $sensitive != 1 ]]; then
      local l
      while IFS= read -r l; do
        gaia_info "[dry-run] diff: $l"
      done < <(diff -u --label "current:$target" --label "new:$target" \
        <(((exists)) && printf '%s\n' "$current") <(printf '%s\n' "$content") | tail -n +3 || true)
    fi
    return 0
  fi
  local dir tmp
  dir=$(dirname "$real")
  if [[ ! -d $dir ]]; then
    gaia_run mkdir -p "$dir"
  fi
  tmp=$(mktemp "$dir/.gaia.XXXXXX")
  printf '%s\n' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  if [[ -n $validator ]] && ! "$validator" "$tmp"; then
    rm -f "$tmp"
    gaia_error "validation of the new file failed; nothing was changed" "file=$target"
    return 1
  fi
  mv -f "$tmp" "$real"
  if ((exists)); then
    gaia_info "file updated" "file=$target" "mode=$mode"
  else
    gaia_info "file created" "file=$target" "mode=$mode"
  fi
}

# gaia_ensure_dir <path> <mode> [owner:group]
gaia_ensure_dir() {
  local target=$1 mode=$2 owner=${3:-} real changed=0
  real=$(gaia_path "$target")
  if [[ ! -d $real ]]; then
    gaia_run mkdir -p "$real"
    changed=1
  fi
  if [[ ! -d $real ]] || [[ $(stat -c %a "$real") != "${mode#0}" ]]; then
    gaia_run chmod "$mode" "$real"
    changed=1
  fi
  if [[ -n $owner ]]; then
    gaia_ensure_owner "$target" "$owner"
    ((GAIA_CHANGED)) && changed=1
  fi
  GAIA_CHANGED=$changed
  ((changed)) || gaia_debug "directory already correct" "dir=$target"
}

# gaia_ensure_owner <path> <owner:group>
gaia_ensure_owner() {
  local target=$1 owner=$2 real
  real=$(gaia_path "$target")
  GAIA_CHANGED=0
  if [[ -e $real ]] && [[ $(stat -c '%U:%G' "$real") == "$owner" ]]; then
    return 0
  fi
  GAIA_CHANGED=1
  gaia_run chown "$owner" "$real"
}

# Writes a file and, if it changed, runs a check command; on failure the previous content is
# restored (or the file removed) and the step fails.
# gaia_ensure_checked_file <path> <mode> <content> <description> <check command...>
gaia_ensure_checked_file() {
  local target=$1 mode=$2 content=$3 what=$4 real had=0 previous="" out rc=0 line
  shift 4
  real=$(gaia_path "$target")
  if [[ -f $real ]]; then
    had=1
    previous=$(<"$real")
  fi
  gaia_ensure_file "$target" "$mode" "$content"
  ((GAIA_CHANGED)) || return 0
  gaia_is_dry_run && return 0
  out=$("$@" 2>&1) || rc=$?
  if ((rc != 0)); then
    while IFS= read -r line; do
      [[ -n $line ]] && gaia_error "$what: $line"
    done <<<"$out"
    if ((had)); then printf '%s\n' "$previous" >"$real"; else rm -f "$real"; fi
    gaia_fail "$what rejected the new configuration; file restored" "file=$target"
  fi
  gaia_info "$what accepted the configuration"
  GAIA_CHANGED=1
}

# ---------------------------------------------------------------------------------------------
# SSH public keys
# ---------------------------------------------------------------------------------------------
# One OpenSSH public key: type, base64 body and optional comment (group 5).
GAIA_KEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+([A-Za-z0-9+/]{16,}={0,3})([[:space:]]+(.*))?$'

# Prints the "type body [comment]" part of an authorized_keys line, dropping any leading options
# (e.g. the command="echo 'Please login as...'" prefix that cloud images put in root's file).
gaia_key_from_line() {
  local line=${1%$'\r'} field type="" rest
  local -a fields=()
  [[ $line =~ ^[[:space:]]*(#|$) ]] && return 1
  rest=$line
  read -r -a fields <<<"$line"
  for field in "${fields[@]}"; do
    if [[ -n $type ]]; then
      rest=${rest#*"$type"}
      rest=${rest#"${rest%%[![:space:]]*}"}
      [[ "$type $rest" =~ $GAIA_KEY_RE ]] || return 1
      printf '%s' "$type $rest"
      return 0
    fi
    if [[ $field =~ ^(ssh-|ecdsa-|sk-) ]]; then type=$field; fi
  done
  return 1
}

# Number of lines in an authorized_keys file that hold a recognizable public key.
gaia_count_valid_keys() {
  local file=$1 line n=0
  [[ -f $file ]] || { echo 0; return 0; }
  while IFS= read -r line; do
    gaia_key_from_line "$line" >/dev/null && n=$((n + 1))
  done <"$file"
  echo "$n"
}

# ---------------------------------------------------------------------------------------------
# System helpers
# ---------------------------------------------------------------------------------------------
gaia_package_installed() {
  # ${Status} is a dpkg-query format, not a shell expansion.
  # shellcheck disable=SC2016
  [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]
}

gaia_user_in_group() {
  local g
  for g in $(id -nG "$1" 2>/dev/null || true); do
    [[ $g == "$2" ]] && return 0
  done
  return 1
}

# Running inside a container (Docker, Podman, LXC...)? Kernel tunables, swap and AppArmor are owned
# by the host there.
gaia_in_container() {
  if [[ -n ${GAIA_CONTAINER:-} ]]; then [[ $GAIA_CONTAINER == 1 ]]; return; fi
  [[ -f $(gaia_path /.dockerenv) || -f $(gaia_path /run/.containerenv) ]] && return 0
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --container --quiet 2>/dev/null && return 0
  fi
  return 1
}

# apt-get options used everywhere (non-interactive, keeps local config files).
# shellcheck disable=SC2034
GAIA_APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive

# apt-get update only if Gaia's last update is older than GAIA_APT_UPDATE_MAX_AGE, or if forced
# ("force", used right after a new repository is added). Called with "force" from steps and modules,
# which shellcheck does not see when checking this file alone.
# shellcheck disable=SC2120
gaia_apt_update() {
  local stamp now age
  stamp=$(gaia_path /var/lib/gaia/apt-update.stamp)
  printf -v now '%(%s)T' -1
  if [[ ${1:-} != force && -f $stamp ]]; then
    age=$((now - $(stat -c %Y "$stamp")))
    if ((age < ${GAIA_APT_UPDATE_MAX_AGE:-3600})); then
      gaia_debug "apt lists are recent; no apt-get update" "age_s=$age"
      return 0
    fi
  fi
  gaia_run apt-get "${GAIA_APT_OPTS[@]}" update
  if ! gaia_is_dry_run; then
    mkdir -p "$(dirname "$stamp")"
    : >"$stamp"
  fi
}

# Installs the packages that are missing (no-op if all are present).
gaia_apt_install() {
  local p
  local -a missing=()
  for p in "$@"; do
    gaia_package_installed "$p" || missing+=("$p")
  done
  ((${#missing[@]})) || return 0
  gaia_apt_update ""
  gaia_run apt-get "${GAIA_APT_OPTS[@]}" install --no-install-recommends "${missing[@]}"
}

# Verifies that an OpenPGP key file has the expected fingerprint (without touching any keyring).
gaia_key_fingerprint_ok() {
  local file=$1 expected=$2 home fprs
  [[ -s $file ]] || return 1
  home=$(mktemp -d)
  fprs=$(GNUPGHOME=$home gpg --batch --quiet --show-keys --with-colons "$file" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' || true)
  rm -rf "$home"
  grep -qx "$expected" <<<"$fprs"
}

# Downloads an apt repository signing key and installs it only if the fingerprint matches.
# gaia_ensure_repo_key <url> <keyring path> <fingerprint> <name>
gaia_ensure_repo_key() {
  local url=$1 keyring=$2 fpr=$3 name=$4 real tmp
  real=$(gaia_path "$keyring")
  if gaia_key_fingerprint_ok "$real" "$fpr"; then
    gaia_info "$name repository key already installed and verified" "fpr=$fpr"
    return 0
  fi
  if gaia_is_dry_run; then
    gaia_run curl -fsSL "$url" -o "$keyring"
    gaia_info "[dry-run] would verify the key fingerprint" "expected=$fpr"
    return 0
  fi
  gaia_ensure_dir /etc/apt/keyrings 0755
  tmp=$(mktemp)
  gaia_run curl -fsSL --max-time 60 "$url" -o "$tmp"
  if ! gaia_key_fingerprint_ok "$tmp" "$fpr"; then
    rm -f "$tmp"
    gaia_fail "the key downloaded from $url does not have the expected fingerprint ($fpr); repository NOT installed"
  fi
  install -m 0644 "$tmp" "$real"
  rm -f "$tmp"
  gaia_info "$name repository key installed" "file=$keyring" "fpr=$fpr"
}

# ---------------------------------------------------------------------------------------------
# Firewall (ufw) helpers shared by steps and modules.
# ---------------------------------------------------------------------------------------------
gaia_ufw_active() {
  command -v ufw >/dev/null 2>&1 && [[ $(ufw status 2>/dev/null | head -n1) == "Status: active" ]]
}

# gaia_ufw_ensure <action words...>   e.g. "allow 80/tcp", "limit 22/tcp",
#                                          "route allow proto tcp from any to any port 80"
gaia_ufw_ensure() {
  local rule="$*" added
  added=$(ufw show added 2>/dev/null || true)
  if grep -qxF "ufw $rule" <<<"$added"; then
    gaia_debug "firewall rule already present" "rule=$rule"
  else
    # shellcheck disable=SC2086
    gaia_run ufw $rule
  fi
}

# ---------------------------------------------------------------------------------------------
# Interactive input. Reads from the terminal even when the script itself arrives through a pipe
# (curl ... | sudo bash). GAIA_TTY_DEVICE exists for tests.
# ---------------------------------------------------------------------------------------------
gaia_tty_available() {
  local dev=${GAIA_TTY_DEVICE:-/dev/tty}
  [[ -r $dev ]] && { : <"$dev"; } 2>/dev/null
}

# gaia_prompt <question> <default>  -> answer in REPLY (default when empty).
gaia_prompt() {
  local question=$1 default=${2:-} dev=${GAIA_TTY_DEVICE:-/dev/tty} answer=""
  if [[ -n $default ]]; then
    printf '[gaia] %s [%s]: ' "$question" "$default" >&2
  else
    printf '[gaia] %s: ' "$question" >&2
  fi
  # One descriptor for the whole run, so consecutive questions read consecutive lines.
  if [[ -z ${GAIA__TTY_FD:-} ]]; then exec {GAIA__TTY_FD}<"$dev"; fi
  IFS= read -r -u "$GAIA__TTY_FD" answer || answer=""
  answer=${answer%$'\r'}
  REPLY=${answer:-$default}
}
