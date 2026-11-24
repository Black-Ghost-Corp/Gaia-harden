#!/usr/bin/env bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# Fake system used by the unit tests.
#
# Every system command (apt-get, systemctl, useradd, ufw, sshd, docker, curl...) becomes a shim that
# calls this file with the command name. The call is recorded in $STUB_STATE/calls.log and the
# machine state is simulated in files under $STUB_STATE, so a second run sees what the first one did
# (idempotency tests).
#
# Forced failure: if $STUB_STATE/rc/<cmd>_<arg1> or $STUB_STATE/rc/<cmd> exists, the command prints
# $STUB_STATE/out/<same name> (if any) and exits with the code stored in the rc file.
set -euo pipefail

cmd=$1
shift
: "${STUB_STATE:?STUB_STATE is not set}"
STATE=$STUB_STATE
ROOT=${GAIA_ROOT:-}

printf '%s\n' "$cmd${*:+ $*}" >>"$STATE/calls.log"

for key in "${cmd}_${1:-}" "$cmd"; do
  if [[ -f $STATE/rc/$key ]]; then
    if [[ -f $STATE/out/$key ]]; then cat "$STATE/out/$key"; fi
    exit "$(cat "$STATE/rc/$key")"
  fi
done

has_line() { [[ -f $2 ]] && grep -qxF -- "$1" "$2"; }
add_line() { has_line "$1" "$2" || printf '%s\n' "$1" >>"$2"; }
del_line() {
  [[ -f $2 ]] || return 0
  grep -vxF -- "$1" "$2" >"$2.tmp" || true
  mv "$2.tmp" "$2"
}
unit_name() { local u=$1; printf '%s' "${u%.service}"; }

fake_id() {
  local op="" u=""
  for a in "$@"; do
    case $a in
      -*) op+=${a#-} ;;
      *) u=$a ;;
    esac
  done
  if [[ -z $u ]]; then
    if [[ $op == u ]]; then echo "${STUB_EUID:-0}"; else echo root; fi
    return 0
  fi
  if [[ ! -f $STATE/users/$u ]]; then
    echo "id: '$u': no such user" >&2
    return 1
  fi
  local -a groups
  read -r -a groups <"$STATE/users/$u"
  case $op in
    u) echo 1000 ;;
    gn | ng) echo "${groups[0]}" ;;
    nG | Gn) echo "${groups[*]}" ;;
    *) echo "uid=1000($u)" ;;
  esac
}

fake_getent() {
  local db=$1 name=$2
  case $db in
    passwd)
      [[ -f $STATE/users/$name ]] || return 2
      echo "$name:x:1000:1000:User:/home/$name:/bin/bash"
      ;;
    group)
      has_line "$name" "$STATE/groups" || return 2
      echo "$name:x:999:"
      ;;
  esac
}

fake_useradd() {
  local list="" u="" next=""
  for a in "$@"; do
    if [[ -n $next ]]; then
      [[ $next == G ]] && list=${a//,/ }
      next=""
      continue
    fi
    case $a in
      -G | --groups) next=G ;;
      -s | --shell | -c | --comment | -d | --home-dir) next=x ;;
      -*) ;;
      *) u=$a ;;
    esac
  done
  [[ ! -f $STATE/users/$u ]] || { echo "useradd: user '$u' already exists" >&2; return 9; }
  echo "$u $list" >"$STATE/users/$u"
  echo L >"$STATE/users/$u.password"
  mkdir -p "$ROOT/home/$u"
}

fake_usermod() {
  local g="" u=""
  while (($#)); do
    case $1 in
      -aG | -G) g=$2; shift ;;
      -a) ;;
      *) u=$1 ;;
    esac
    shift
  done
  local -a current
  read -r -a current <"$STATE/users/$u"
  echo "${current[*]} $g" >"$STATE/users/$u"
}

fake_passwd() {
  # passwd -S user | passwd -l user
  local u=${*: -1}
  if [[ $1 == -l ]]; then
    echo L >"$STATE/users/$u.password"
    return 0
  fi
  echo "$u $(cat "$STATE/users/$u.password" 2>/dev/null || echo L) 2026-01-01 0 99999 7 -1"
}

fake_chown() {
  local owner="" a
  for a in "$@"; do
    case $a in
      -*) ;;
      *)
        if [[ -z $owner ]]; then
          owner=$a
          [[ $owner == *:* ]] || owner="$owner:$owner"
        else
          printf '%s\t%s\n' "$a" "$owner" >>"$STATE/owners"
        fi
        ;;
    esac
  done
}

fake_stat() {
  local fmt="" target="${*: -1}" prev=""
  for a in "$@"; do
    [[ $prev == -c ]] && fmt=$a
    prev=$a
  done
  if [[ $fmt == '%U:%G' && -f $STATE/owners ]]; then
    local owner
    owner=$(awk -F'\t' -v p="$target" '$1 == p { d = $2 } END { print d }' "$STATE/owners")
    if [[ -n $owner ]]; then
      echo "$owner"
      return 0
    fi
  fi
  PATH=$STUB_REAL_PATH exec stat "$@"
}

fake_dpkg-query() {
  local p=${*: -1}
  if has_line "$p" "$STATE/packages"; then
    printf 'install ok installed'
  else
    echo "dpkg-query: no packages found matching $p" >&2
    return 1
  fi
}

fake_dpkg() {
  [[ ${1:-} == --print-architecture ]] && echo "${STUB_ARCH:-amd64}"
}

fake_apt-get() {
  local sim=0 sub="" skip=0 a
  local -a pkgs=()
  for a in "$@"; do
    if ((skip)); then skip=0; continue; fi
    case $a in
      -o) skip=1 ;;
      -s | --simulate) sim=1 ;;
      -*) ;;
      *) if [[ -z $sub ]]; then sub=$a; else pkgs+=("$a"); fi ;;
    esac
  done
  case $sub in
    update) echo "Reading package lists... Done" ;;
    full-upgrade)
      if ((sim)); then cat "$STATE/updates" 2>/dev/null || true; else : >"$STATE/updates"; fi
      ;;
    install)
      for a in "${pkgs[@]}"; do
        add_line "$a" "$STATE/packages"
        if [[ $a == docker-ce ]]; then add_line docker "$STATE/groups"; fi
        if [[ $a == ufw ]]; then
          mkdir -p "$ROOT/etc/ufw"
          [[ -f $ROOT/etc/ufw/after.rules ]] || printf '*filter\n:ufw-after-input - [0:0]\nCOMMIT\n' >"$ROOT/etc/ufw/after.rules"
        fi
      done
      ;;
    remove | purge)
      for a in "${pkgs[@]}"; do del_line "$a" "$STATE/packages"; done
      ;;
  esac
}

fake_systemctl() {
  local sub="" a now=0 quiet=0
  local -a units=()
  for a in "$@"; do
    case $a in
      --now) now=1 ;;
      --quiet | -q) quiet=1 ;;
      -*) ;;
      *) if [[ -z $sub ]]; then sub=$a; else units+=("$(unit_name "$a")"); fi ;;
    esac
  done
  mkdir -p "$STATE/units"
  local u=${units[0]:-}
  if ((quiet)); then exec >/dev/null; fi
  case $sub in
    is-active)
      if [[ -f $STATE/units/$u.active ]]; then echo active; else echo inactive; return 3; fi
      ;;
    is-enabled)
      if [[ -f $STATE/units/$u.enabled ]]; then echo enabled; else echo disabled; return 1; fi
      ;;
    enable)
      touch "$STATE/units/$u.enabled"
      if ((now)); then touch "$STATE/units/$u.active"; fi
      ;;
    disable)
      rm -f "$STATE/units/$u.enabled"
      if ((now)); then rm -f "$STATE/units/$u.active"; fi
      ;;
    start | restart) touch "$STATE/units/$u.active" ;;
    reload) [[ -f $STATE/units/$u.active ]] || { echo "unit $u not active" >&2; return 1; } ;;
    stop) rm -f "$STATE/units/$u.active" ;;
    daemon-reload) ;;
  esac
}

fake_timedatectl() {
  case $1 in
    show)
      case $3 in
        Timezone) cat "$STATE/timezone" 2>/dev/null || echo Etc/UTC ;;
        NTP) cat "$STATE/ntp" 2>/dev/null || echo no ;;
      esac
      ;;
    set-timezone) echo "$2" >"$STATE/timezone" ;;
    set-ntp) [[ $2 == true ]] && echo yes >"$STATE/ntp" ;;
  esac
}

fake_hostnamectl() {
  [[ ${1:-} == set-hostname ]] && printf '%s\n' "$2" >"$ROOT/etc/hostname"
  return 0
}

fake_sshd() {
  case ${1:-} in
    -t) return 0 ;;
    -T)
      # Effective configuration: the first value found wins, like the real sshd (drop-ins included
      # at the top of sshd_config are read before the rest). AllowUsers prints one line per user.
      local -a files=()
      local f
      for f in "$ROOT"/etc/ssh/sshd_config.d/*.conf; do [[ -f $f ]] && files+=("$f"); done
      files+=("$ROOT/etc/ssh/sshd_config")
      awk '
        BEGIN { v["port"]="22"; v["permitrootlogin"]="without-password";
                v["passwordauthentication"]="yes"; v["kbdinteractiveauthentication"]="yes";
                v["pubkeyauthentication"]="yes"; v["x11forwarding"]="no"; v["maxauthtries"]="6";
                v["logingracetime"]="120"; v["allowtcpforwarding"]="yes"; v["allowagentforwarding"]="yes";
                v["kexalgorithms"]="curve25519-sha256,diffie-hellman-group14-sha256";
                v["ciphers"]="chacha20-poly1305@openssh.com,aes128-ctr"; v["macs"]="hmac-sha2-256,umac-64@openssh.com" }
        /^[[:space:]]*#/ || NF < 2 { next }
        {
          k = tolower($1); if (k == "include") next
          if (k == "allowusers") { if (!("allowusers" in seen)) { seen[k]=1; for (i = 2; i <= NF; i++) users[++nu] = $i } ; next }
          if (!(k in seen)) { seen[k]=1; v[k]=$2 }
        }
        END { for (k in v) print k, v[k]; for (i = 1; i <= nu; i++) print "allowusers", users[i] }
      ' "${files[@]}" 2>/dev/null | sort
      ;;
  esac
}

# "ssh -Q <kind>": algorithms of an OpenSSH 9.6 (Ubuntu 24.04): no ML-KEM yet.
fake_ssh() {
  [[ ${1:-} == -Q ]] || return 0
  case $2 in
    kex) printf '%s\n' diffie-hellman-group14-sha256 diffie-hellman-group16-sha512 diffie-hellman-group18-sha512 \
      ecdh-sha2-nistp256 curve25519-sha256 curve25519-sha256@libssh.org sntrup761x25519-sha512@openssh.com ;;
    cipher) printf '%s\n' aes128-ctr aes192-ctr aes256-ctr aes128-gcm@openssh.com aes256-gcm@openssh.com chacha20-poly1305@openssh.com ;;
    mac) printf '%s\n' hmac-sha2-256 hmac-sha2-512 umac-128@openssh.com hmac-sha2-256-etm@openssh.com \
      hmac-sha2-512-etm@openssh.com umac-128-etm@openssh.com ;;
  esac
}

fake_ufw() {
  mkdir -p "$STATE/ufw"
  case $1 in
    status)
      if [[ -f $STATE/ufw/active ]]; then echo "Status: active"; else echo "Status: inactive"; fi
      ;;
    show)
      echo "Added user rules (see 'ufw status' for running firewall):"
      if [[ -s $STATE/ufw/rules ]]; then cat "$STATE/ufw/rules"; else echo "(None)"; fi
      ;;
    default)
      local file=$ROOT/etc/default/ufw
      case "$2 $3" in
        "deny incoming") sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' "$file" ;;
        "allow outgoing") sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' "$file" ;;
      esac
      ;;
    allow | limit | route)
      if has_line "ufw $*" "$STATE/ufw/rules"; then echo "Skipping adding existing rule"; else echo "ufw $*" >>"$STATE/ufw/rules"; echo "Rules updated"; fi
      ;;
    reload) echo "Firewall reloaded" ;;
    --force) [[ $2 == enable ]] && touch "$STATE/ufw/active" && echo "Firewall is active and enabled on system startup" ;;
  esac
}

fake_fail2ban-client() { echo "OK"; }

fake_curl() {
  local out="" prev="" url="" write=0 a
  for a in "$@"; do
    [[ $prev == -o ]] && out=$a
    [[ $a == -w ]] && write=1
    [[ $a == http* ]] && url=$a
    prev=$a
  done
  local host=${url#*://}
  host=${host%%/*}
  if has_line "$host" "$STATE/curl_fail"; then
    ((write)) && printf '000'
    echo "curl: (6) Could not resolve host: $host" >&2
    return 6
  fi
  # GitHub public keys: the test writes $STATE/github_keys/<user>.
  if [[ $url =~ ^https://github\.com/([A-Za-z0-9-]+)\.keys$ ]]; then
    local f=$STATE/github_keys/${BASH_REMATCH[1]}
    [[ -f $f ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; return 22; }
    cat "$f"
    return 0
  fi
  # Caddy repository key (caddy module).
  if [[ $url == https://dl.cloudsmith.io/* && -n $out && $out != /dev/null ]]; then
    cat "$STATE/caddy_key" 2>/dev/null >"$out" || echo "FAKE-GPG-KEY-CADDY" >"$out"
  elif [[ -n $out && $out != /dev/null ]]; then
    cat "$STATE/docker_key" 2>/dev/null >"$out" || echo "FAKE-GPG-KEY-DOCKER" >"$out"
  fi
  if ((write)); then printf '200'; fi
}

fake_gpg() {
  local file=${*: -1}
  if grep -q FAKE-GPG-KEY-DOCKER "$file" 2>/dev/null; then
    echo "pub:-:4096:1:8D81803C0EBFCD88:1487788586:::-:::scESA::::::23::0:"
    echo "fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:"
  elif grep -q FAKE-GPG-KEY-CADDY "$file" 2>/dev/null; then
    echo "pub:-:4096:1:155B6D79CA56EA34:1459530465:::-:::scSC::::::23::0:"
    echo "fpr:::::::::65760C51EDEA2017CEA2CA15155B6D79CA56EA34:"
  else
    echo "fpr:::::::::0000000000000000000000000000000000000000:"
  fi
}

fake_df() {
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
  echo "/dev/sda1 104857600 1000 ${STUB_DF_KB:-52428800} 1% /"
}

# "ss -H -tulpn": $STATE/ss if the test wrote one, otherwise a fresh server with sshd only.
fake_ss() {
  if [[ -f $STATE/ss ]]; then
    cat "$STATE/ss"
  else
    printf '%s\n' 'tcp   LISTEN 0      4096   0.0.0.0:22   0.0.0.0:*    users:(("sshd",pid=801,fd=3))' \
      'tcp   LISTEN 0      4096      [::]:22      [::]:*    users:(("sshd",pid=801,fd=4))' \
      'udp   UNCONN 0      0      127.0.0.53%lo:53   0.0.0.0:*    users:(("systemd-resolve",pid=500,fd=13))'
  fi
}

fake_sysctl() { return 0; }

fake_swapon() {
  if [[ ${1:-} == --show* ]]; then
    cat "$STATE/swaps" 2>/dev/null || true
    return 0
  fi
  add_line "${1#"$ROOT"}" "$STATE/swaps"
}

fake_fallocate() { : >"${*: -1}"; }
fake_mkswap() { echo "Setting up swapspace version 1"; }

fake_postconf() {
  case ${1:-} in
    -h) cat "$STATE/postfix_inet_interfaces" 2>/dev/null || echo all ;;
    -e) echo "${2#*=}" >"$STATE/postfix_inet_interfaces" ;;
  esac
}

fake_update-exim4.conf() { return 0; }

# "lynis audit system ... --report-file F": writes a report with the next score from
# $STATE/lynis_scores (one per line), or 60.
fake_lynis() {
  local report="" prev="" a score=60
  for a in "$@"; do
    [[ $prev == --report-file ]] && report=$a
    prev=$a
  done
  if [[ -s $STATE/lynis_scores ]]; then
    score=$(head -n1 "$STATE/lynis_scores")
    sed -i 1d "$STATE/lynis_scores"
  fi
  [[ -n $report ]] && printf 'hardening_index=%s\nwarning[]=SSH-7408|x|\nsuggestion[]=KRNL-6000|y|\n' "$score" >"$report"
  echo "Lynis audit done"
}

fake_docker() {
  [[ ${1:-} == run ]] && echo "Hello from Docker!"
  return 0
}

fake_visudo() { echo "parsed OK"; }
# caddy validate: forced failure with force_failure caddy_validate (generic mechanism at the top).
fake_caddy() { echo "Valid configuration"; }

"fake_$cmd" "$@"
