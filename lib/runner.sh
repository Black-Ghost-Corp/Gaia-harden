# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# lib/runner.sh — command line, step discovery, interactive wizard and ordered execution, with a
# duration per step and a summary table at the end.
#
# Step kinds:
#   base    lib/steps/NN-name.sh, define step_run(), always run. Each runs in its own subshell.
#   module  lib/modules/NN-name.sh, define step_run(), run only when selected (--modules / GAIA_MODULES).
#   custom  every executable *.sh in GAIA_EXTRA_STEPS_DIR (lexical order), run as a separate process
#           with the GAIA_* variables exported.
# Order: base steps numbered below 90, modules, custom steps, then base steps numbered 90 or more
# (the final audit and the summary).

GAIA_VERSION="0.1.0"

gaia_usage() {
  cat <<EOF
Gaia $GAIA_VERSION — turns a fresh Ubuntu/Debian server into a hardened host.

usage: sudo ./bootstrap.sh [options]

  --modules LIST       optional modules to install, comma separated (e.g. docker,caddy; "none" or "all")
  --admin-user NAME    administrator account (default: the user who ran sudo)
  --ssh-key KEY        administrator public key (repeatable)
  --github-keys USER   import public keys from https://github.com/USER.keys (repeatable)
  --ssh-port PORT      SSH port (default 22)
  --allow RULES        extra inbound firewall rules, comma separated (e.g. 80/tcp,443/tcp)
  --hostname NAME      set the host name
  --timezone TZ        time zone (default UTC)
  --swap SIZE          create a swap file (e.g. 2G)
  --no-audit           skip the Lynis security audit before and after
  --config FILE        configuration file (default: gaia.conf next to bootstrap.sh, if present)
  --dry-run            show what each step would change, without changing anything
  --only LIST          run only these steps (comma separated)
  --skip LIST          skip these steps (repeatable)
  --list-steps         list the steps and exit
  --yes, -y            do not ask anything (non-interactive)
  --version            print the version and exit
  -h, --help           this help
EOF
}

gaia_step_description() {
  local d
  d=$(sed -n 's/^# gaia-description: *//p' "$1" | head -n1)
  printf '%s' "${d:-(no description)}"
}

# Fills GAIA_STEPS (names), GAIA_STEP_FILE[name], GAIA_STEP_KIND[name] (base|module|custom) and
# GAIA_AVAILABLE_MODULES.
gaia_discover_steps() {
  local base_dir=${GAIA_STEPS_DIR:-$GAIA_HOME/lib/steps} module_dir=${GAIA_MODULES_DIR:-$GAIA_HOME/lib/modules}
  local f name num
  local -a first=() last=() modules=() custom=()
  GAIA_STEPS=()
  GAIA_AVAILABLE_MODULES=""
  declare -gA GAIA_STEP_FILE=() GAIA_STEP_KIND=()
  for f in "$base_dir"/[0-9][0-9]-*.sh; do
    [[ -f $f ]] || continue
    name=$(basename "$f" .sh)
    num=${name%%-*}
    name=${name#*-}
    GAIA_STEP_FILE[$name]=$f
    GAIA_STEP_KIND[$name]=base
    if ((10#$num >= 90)); then last+=("$name"); else first+=("$name"); fi
  done
  for f in "$module_dir"/[0-9][0-9]-*.sh; do
    [[ -f $f ]] || continue
    name=$(basename "$f" .sh)
    name=${name#*-}
    [[ -z ${GAIA_STEP_FILE[$name]:-} ]] || gaia_die "module name clashes with a step: $name ($f)"
    GAIA_STEP_FILE[$name]=$f
    GAIA_STEP_KIND[$name]=module
    modules+=("$name")
    GAIA_AVAILABLE_MODULES+="${GAIA_AVAILABLE_MODULES:+ }$name"
  done
  if [[ -n ${GAIA_EXTRA_STEPS_DIR:-} && -d ${GAIA_EXTRA_STEPS_DIR:-} ]]; then
    for f in "$GAIA_EXTRA_STEPS_DIR"/*.sh; do
      [[ -f $f ]] || continue
      name=$(basename "$f" .sh)
      [[ $name =~ ^[0-9]+-(.+)$ ]] && name=${BASH_REMATCH[1]}
      name="custom:$name"
      [[ -z ${GAIA_STEP_FILE[$name]:-} ]] || gaia_die "duplicate custom step name: $name ($f)"
      GAIA_STEP_FILE[$name]=$f
      GAIA_STEP_KIND[$name]=custom
      custom+=("$name")
    done
  fi
  GAIA_STEPS=("${first[@]}" "${modules[@]}" "${custom[@]}" "${last[@]}")
}

gaia_list_steps() {
  local i=0 name
  for name in "${GAIA_STEPS[@]}"; do
    i=$((i + 1))
    printf '%3d  %-24s %-7s %s\n' "$i" "$name" "${GAIA_STEP_KIND[$name]}" "$(gaia_step_description "${GAIA_STEP_FILE[$name]}")"
  done
}

gaia__validate_list() {
  local name
  for name in "$@"; do
    if [[ -z ${GAIA_STEP_FILE[$name]:-} ]]; then
      gaia_error "unknown step: $name (see ./bootstrap.sh --list-steps)"
      exit 2
    fi
  done
}

# Module menu, shown when nothing chose the modules and a terminal is available.
gaia__ask_modules() {
  local m i=0 answer items=""
  local -a names=()
  printf '[gaia] The hardened base (SSH, firewall, updates, kernel...) always runs. Optional modules:\n' >&2
  for m in $GAIA_AVAILABLE_MODULES; do
    i=$((i + 1))
    names+=("$m")
    printf '  %d) %-8s %s\n' "$i" "$m" "$(gaia_step_description "${GAIA_STEP_FILE[$m]}")" >&2
  done
  gaia_prompt "Modules to install (numbers or names, comma separated; Enter = none)" ""
  answer=${REPLY// /}
  for i in ${answer//,/ }; do
    if [[ $i =~ ^[0-9]+$ ]] && ((i >= 1 && i <= ${#names[@]})); then items+="${names[i - 1]} "; else items+="$i "; fi
  done
  gaia_modules_normalize "$items" "menu answer"
}

# Administrator: --admin-user/GAIA_ADMIN_USER > the user who ran sudo > question in the terminal.
gaia__resolve_admin() {
  [[ -z $GAIA_ADMIN_USER ]] || return 0
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root && $SUDO_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    GAIA_ADMIN_USER=$SUDO_USER
    gaia_info "administrator not set; using the user who ran sudo" "admin=$GAIA_ADMIN_USER"
    return 0
  fi
  if [[ $1 == 1 ]]; then
    gaia_prompt "Administrator user name to create (key-only SSH login, sudo)" "admin"
    GAIA_ADMIN_USER=$REPLY
    gaia__check GAIA_ADMIN_USER '^[a-z_][a-z0-9_-]{0,31}$' "Linux user name"
    [[ $GAIA_ADMIN_USER != root ]] || gaia_die "the administrator cannot be root"
  fi
}

gaia__pad() {
  local s=$1 width=$2 n
  # Count characters, not bytes, even under LC_ALL=C: drop UTF-8 continuation bytes (0x80-0xBF).
  n=$(
    LC_ALL=C
    t=${s//[$'\x80'-$'\xbf']/}
    printf '%s' "${#t}"
  )
  printf '%s%*s' "$s" $((width > n ? width - n : 0)) ""
}

gaia__table_row() {
  printf '| %s | %s | %s |' "$(gaia__pad "$1" 24)" "$(gaia__pad "$2" 12)" "$(gaia__pad "$3" 9)"
}

gaia__duration() {
  local us=$1
  printf '%d.%03ds' $((us / 1000000)) $(((us / 1000) % 1000))
}

gaia__now_us() {
  local t=${EPOCHREALTIME//[!0-9]/}
  printf '%s' "$((10#$t))"
}

# Runs one step and leaves its status in GAIA__STATUS.
gaia__run_step() {
  local name=$1 file=${GAIA_STEP_FILE[$1]} rc=0
  rm -f "$GAIA_RUN_DIR/changed" "$GAIA_RUN_DIR/skipped"
  GAIA_STEP=$name
  gaia_info "step started" "description=$(gaia_step_description "$file")"
  # The subshell cannot run in an "if"/"||" context (bash would ignore set -e inside it), so the
  # main process' trap and errexit are suspended only around the call.
  trap - ERR
  set +e
  if [[ ${GAIA_STEP_KIND[$name]} != custom ]]; then
    (
      gaia_step_mode
      # shellcheck source=/dev/null
      source "$file"
      step_run
    )
    rc=$?
  elif [[ -x $file ]]; then
    GAIA_STEP=$name "$file"
    rc=$?
  else
    gaia_warn "custom step is not executable; skipping (use chmod +x)" "file=$file"
    printf 'not executable\n' >"$GAIA_RUN_DIR/skipped"
  fi
  set -e
  trap 'gaia__on_error "$?" "$LINENO" "${BASH_SOURCE[0]:-?}" "$BASH_COMMAND"' ERR
  GAIA_STEP=$name
  if ((rc != 0)); then
    GAIA__STATUS="failed"
  elif [[ -f $GAIA_RUN_DIR/skipped ]]; then
    GAIA__STATUS="skipped"
  elif [[ -f $GAIA_RUN_DIR/changed ]]; then
    if gaia_is_dry_run; then GAIA__STATUS="would change"; else GAIA__STATUS="done"; fi
  else
    GAIA__STATUS="ok"
  fi
}

gaia__prepare_log() {
  local dir ts
  # GAIA_LOG_DIR comes from gaia_config_defaults (lib/config.sh).
  # shellcheck disable=SC2153
  dir=$(gaia_path "$GAIA_LOG_DIR")
  mkdir -p "$dir"
  chmod 700 "$dir"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  GAIA_LOG_FILE="$dir/gaia-$ts.log"
  if gaia_is_dry_run; then GAIA_LOG_FILE="$dir/gaia-$ts-dry-run.log"; fi
  : >>"$GAIA_LOG_FILE"
  chmod 600 "$GAIA_LOG_FILE"
  export GAIA_LOG_FILE
}

gaia__lock() {
  local lock
  lock=$(gaia_path /run/gaia.lock)
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  flock -n 9 || gaia_die "another Gaia run is in progress (lock: /run/gaia.lock)"
}

gaia__confirm() {
  if [[ $GAIA_OPT_YES == 1 ]] || gaia_is_dry_run; then return 0; fi
  gaia_tty_available || gaia_die "no terminal to confirm; run with --yes to apply or --dry-run to preview"
  gaia_prompt "Gaia will change this server (SSH, firewall, packages, kernel settings${GAIA_MODULES:+, $GAIA_MODULES}). Continue? (y/N)" "N"
  [[ $REPLY =~ ^[yY]([eE][sS])?$ ]] || gaia_die "cancelled by the user"
}

# Stores a command line value that overrides gaia.conf.
gaia__cli_set() { GAIA__CLI[$1]=$2; }
gaia__cli_add() { GAIA__CLI[$1]="${GAIA__CLI[$1]:-}${GAIA__CLI[$1]:+$3}$2"; }

gaia_main() {
  local config="$GAIA_HOME/gaia.conf" config_required=0 list=0 arg
  local -a only=() skip=()
  GAIA_OPT_YES=0
  GAIA_DRY_RUN=0
  while (($#)); do
    arg=$1
    case $arg in
      --config) config=${2:?--config needs a file}; config_required=1; shift ;;
      --config=*) config=${arg#*=}; config_required=1 ;;
      --modules | --with) gaia__cli_set GAIA_MODULES "${2?--modules needs a list (e.g. docker,caddy)}"; shift ;;
      --modules=* | --with=*) gaia__cli_set GAIA_MODULES "${arg#*=}" ;;
      --admin-user) gaia__cli_set GAIA_ADMIN_USER "${2:?--admin-user needs a name}"; shift ;;
      --admin-user=*) gaia__cli_set GAIA_ADMIN_USER "${arg#*=}" ;;
      --ssh-key) gaia__cli_add GAIA_ADMIN_SSH_KEYS "${2:?--ssh-key needs a public key}" $'\n'; shift ;;
      --ssh-key=*) gaia__cli_add GAIA_ADMIN_SSH_KEYS "${arg#*=}" $'\n' ;;
      --github-keys) gaia__cli_add GAIA_ADMIN_GITHUB_KEYS "${2:?--github-keys needs a GitHub user}" ' '; shift ;;
      --github-keys=*) gaia__cli_add GAIA_ADMIN_GITHUB_KEYS "${arg#*=}" ' ' ;;
      --ssh-port) gaia__cli_set GAIA_SSH_PORT "${2:?--ssh-port needs a port}"; shift ;;
      --ssh-port=*) gaia__cli_set GAIA_SSH_PORT "${arg#*=}" ;;
      --allow) gaia__cli_set GAIA_FIREWALL_ALLOW "${2//,/ }"; shift ;;
      --allow=*) arg=${arg#*=}; gaia__cli_set GAIA_FIREWALL_ALLOW "${arg//,/ }" ;;
      --hostname) gaia__cli_set GAIA_HOSTNAME "${2:?--hostname needs a name}"; shift ;;
      --hostname=*) gaia__cli_set GAIA_HOSTNAME "${arg#*=}" ;;
      --timezone) gaia__cli_set GAIA_TIMEZONE "${2:?--timezone needs a time zone}"; shift ;;
      --timezone=*) gaia__cli_set GAIA_TIMEZONE "${arg#*=}" ;;
      --swap) gaia__cli_set GAIA_SWAP_SIZE "${2:?--swap needs a size (e.g. 2G)}"; shift ;;
      --swap=*) gaia__cli_set GAIA_SWAP_SIZE "${arg#*=}" ;;
      --no-audit) gaia__cli_set GAIA_AUDIT 0 ;;
      --dry-run) GAIA_DRY_RUN=1 ;;
      --only) IFS=, read -r -a only <<<"${2:?--only needs a list}"; shift ;;
      --only=*) IFS=, read -r -a only <<<"${arg#*=}" ;;
      --skip)
        local -a tmp
        IFS=, read -r -a tmp <<<"${2:?--skip needs a list}"
        skip+=("${tmp[@]}")
        shift
        ;;
      --skip=*)
        local -a tmp
        IFS=, read -r -a tmp <<<"${arg#*=}"
        skip+=("${tmp[@]}")
        ;;
      --list-steps) list=1 ;;
      --yes | -y) GAIA_OPT_YES=1 ;;
      --version) printf 'gaia %s\n' "$GAIA_VERSION"; exit 0 ;;
      -h | --help) gaia_usage; exit 0 ;;
      *) gaia_error "unknown option: $arg"; gaia_usage; exit 2 ;;
    esac
    shift
  done
  export GAIA_DRY_RUN

  if ((list)); then
    gaia_config_load "$config" 0
    gaia_discover_steps
    gaia_list_steps
    exit 0
  fi

  ((BASH_VERSINFO[0] >= 5)) || gaia_die "bash 5 or newer is required (current: $BASH_VERSION)"
  gaia_config_load "$config" "$config_required"
  # The module menu only appears when nothing chose them (an empty GAIA_MODULES in a copied
  # example file still gets the menu; --modules none skips it).
  local modules_chosen=0
  [[ -n ${GAIA__CLI[GAIA_MODULES]+x} || -n $GAIA_MODULES ]] && modules_chosen=1
  # Path of the loaded file, so steps can check what must NOT be in it. Set after sourcing it, so
  # the file itself cannot change it.
  [[ -f $config ]] && export GAIA_CONFIG_FILE=$config
  gaia_discover_steps
  gaia_modules_normalize "$GAIA_MODULES" GAIA_MODULES
  gaia__validate_list "${only[@]}" "${skip[@]}"

  local interactive=0
  if [[ $GAIA_OPT_YES != 1 ]] && ((${#only[@]} == 0)) && gaia_tty_available; then interactive=1; fi
  gaia__resolve_admin "$interactive"
  gaia_config_validate

  [[ $(id -u) == 0 ]] || gaia_die "must run as root (use sudo ./bootstrap.sh ...)"
  gaia_detect_os
  gaia_validate_os
  if ((interactive && !modules_chosen)) && [[ -n $GAIA_AVAILABLE_MODULES ]]; then
    gaia__ask_modules
  fi

  local -A selected=() not_selected=() status=() duration=()
  local name
  if ((${#only[@]})); then
    for name in "${only[@]}"; do selected[$name]=1; done
  else
    for name in "${GAIA_STEPS[@]}"; do
      if [[ ${GAIA_STEP_KIND[$name]} == module ]] && ! gaia_module_selected "$name"; then
        not_selected[$name]=1
      else
        selected[$name]=1
      fi
    done
  fi
  for name in "${skip[@]}"; do unset "selected[$name]"; done
  if [[ -z $GAIA_ADMIN_USER ]] && [[ -n ${selected[admin-user]:-} || -n ${selected[ssh]:-} ]]; then
    gaia_die "no administrator account: use --admin-user NAME (or GAIA_ADMIN_USER in gaia.conf), or run through sudo as the user who will administer the server"
  fi

  gaia__confirm
  gaia__lock
  gaia__prepare_log
  GAIA_RUN_DIR=$(mktemp -d)
  export GAIA_RUN_DIR GAIA_LIB_DIR="$GAIA_HOME/lib" GAIA_HOME GAIA_VERSION
  export "${!GAIA_@}"

  gaia_info "run started" "version=$GAIA_VERSION" "dry_run=$GAIA_DRY_RUN" "config=$([[ -f $config ]] && echo "$config" || echo none)" \
    "system=$GAIA_OS_ID-$GAIA_OS_VERSION" "arch=$GAIA_ARCH" "log=${GAIA_LOG_FILE#"$GAIA_ROOT"}"
  gaia_config_log
  gaia_is_dry_run && gaia_info "dry-run mode: nothing will be changed; each step says what it would change"

  local t0 failures=0 abort=0 started
  started=$(gaia__now_us)
  for name in "${GAIA_STEPS[@]}"; do
    if [[ -z ${selected[$name]:-} ]]; then
      status[$name]="skipped"
      [[ -z ${not_selected[$name]:-} ]] || status[$name]="not selected"
      duration[$name]="-"
      continue
    fi
    if ((abort)); then
      status[$name]="skipped"
      duration[$name]="-"
      GAIA_STEP=$name gaia_warn "step not run because of the previous failure"
      continue
    fi
    t0=$(gaia__now_us)
    gaia__run_step "$name"
    duration[$name]=$(gaia__duration $(($(gaia__now_us) - t0)))
    status[$name]=$GAIA__STATUS
    if [[ $GAIA__STATUS == failed ]]; then
      gaia_error "step finished" "status=${status[$name]}" "duration=${duration[$name]}"
      failures=$((failures + 1))
      abort=1
    else
      gaia_info "step finished" "status=${status[$name]}" "duration=${duration[$name]}"
    fi
  done
  # Read by gaia_log (lib/common.sh) for the step= field of the next lines.
  # shellcheck disable=SC2034
  GAIA_STEP=main

  gaia_info "steps summary:"
  gaia_info "$(gaia__table_row step status duration)"
  for name in "${GAIA_STEPS[@]}"; do
    gaia_info "$(gaia__table_row "$name" "${status[$name]}" "${duration[$name]}")"
  done
  local level=info
  ((failures == 0)) || level=error
  gaia_log "$level" "run finished" "failures=$failures" "total_duration=$(gaia__duration $(($(gaia__now_us) - started)))" \
    "log=${GAIA_LOG_FILE#"$GAIA_ROOT"}"
  rm -rf "$GAIA_RUN_DIR"
  if ((failures > 0)); then exit 1; fi
  exit 0
}
