# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# lib/report.sh — machine-readable report of a run (--report-json FILE), for automation and AI
# agents. Written in plain Bash: jq may not be installed yet on a fresh server.
#
# Schema "gaia-report/1":
#   schema, gaia_version, dry_run, result ("success" | "failed"), failures,
#   started_at, finished_at (UTC, ISO 8601), duration_s,
#   system {os_id, os_version, os_codename, arch, hostname},
#   config {admin_user, ssh_port, modules[], firewall_allow[], audit},
#   steps [{name, kind, status, duration_s}],
#   ports {before[], after[], closed[], exposed_after}   (socket: proto, address, port, process,
#                                                          exposure, exposed)
#   lynis {before, after, gain}   (null when the audit did not run)
#   reboot_required, warnings [{step, message}], errors [{step, message}], next_steps[], tips[], log_file
# Messages come from the log lines, so secrets are already masked.

# JSON string literal of $1 (quotes, backslashes and control characters escaped).
gaia_json_str() {
  local s=$1 out="" c i
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  if [[ $s =~ [[:cntrl:]] ]]; then
    for ((i = 0; i < ${#s}; i++)); do
      c=${s:i:1}
      if [[ $c =~ [[:cntrl:]] ]]; then
        printf -v c '\\u%04x' "'$c"
      fi
      out+=$c
    done
    s=$out
  fi
  printf '"%s"' "$s"
}

# JSON number or null.
gaia__json_num() {
  if [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

# JSON array of strings from the words (or lines with -l) of $2.
gaia__json_list() {
  local mode=$1 text=$2 sep="" item
  local -a items=()
  if [[ $mode == -l ]]; then
    mapfile -t items <<<"$text"
  else
    read -r -a items <<<"$text"
  fi
  printf '['
  for item in "${items[@]}"; do
    [[ -n $item ]] || continue
    printf '%s%s' "$sep" "$(gaia_json_str "$item")"
    sep=","
  done
  printf ']'
}

# Sockets of a "<proto>\t<address>\t<port>\t<process>\t<exposure>" file as a JSON array.
gaia__json_sockets() {
  local file=$1 sep="" proto addr port proc exposure exposed
  printf '['
  if [[ -f $file ]]; then
    while IFS=$'\t' read -r proto addr port proc exposure; do
      [[ -n $proto ]] || continue
      exposed=false
      [[ $exposure == EXPOSED* ]] && exposed=true
      printf '%s{"proto":%s,"address":%s,"port":%s,"process":%s,"exposure":%s,"exposed":%s}' "$sep" \
        "$(gaia_json_str "$proto")" "$(gaia_json_str "$addr")" "$(gaia__json_num "$port")" \
        "$(gaia_json_str "$proc")" "$(gaia_json_str "$exposure")" "$exposed"
      sep=","
    done <"$file"
  fi
  printf ']'
}

# Warnings or errors ($2 = warn|error) collected in $1 ("<level>\t<step>\t<message>").
gaia__json_events() {
  local file=$1 want=$2 sep="" level step msg
  printf '['
  if [[ -f $file ]]; then
    while IFS=$'\t' read -r level step msg; do
      [[ $level == "$want" ]] || continue
      printf '%s{"step":%s,"message":%s}' "$sep" "$(gaia_json_str "$step")" "$(gaia_json_str "$msg")"
      sep=","
    done <"$file"
  fi
  printf ']'
}

# Seconds with millisecond precision from microseconds, or null.
gaia__json_seconds() {
  [[ $1 =~ ^[0-9]+$ ]] || { printf 'null'; return; }
  printf '%d.%03d' $(($1 / 1000000)) $((($1 % 1000000) / 1000))
}

# Writes the report. Arguments: <file> <failures> <started_us> <finished_us> <started_iso>.
# Reads the run state from the runner's arrays (GAIA_STEPS, GAIA_STEP_KIND, GAIA__STATUS_OF,
# GAIA__DURATION_US) and from the files steps left in GAIA_RUN_DIR.
gaia_report_write() {
  local file=$1 failures=$2 started_us=$3 finished_us=$4 started_iso=$5
  local run=$GAIA_RUN_DIR finished_iso tmp name sep="" before after gain=null closed host reboot=false
  TZ=UTC0 printf -v finished_iso '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  host=$(cat "$(gaia_path /etc/hostname)" 2>/dev/null || hostname 2>/dev/null || true)
  [[ -f $(gaia_path /var/run/reboot-required) ]] && reboot=true
  before=$(cat "$run/lynis-before" 2>/dev/null || true)
  after=$(cat "$run/lynis-after" 2>/dev/null || true)
  if [[ $before =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]; then gain=$((after - before)); fi
  # Sockets listening before and no longer listening after (same key: proto, address, port, process).
  closed=$run/ports-closed.exposure
  : >"$closed"
  if [[ -f $run/ports-before.exposure && -f $run/ports-after ]]; then
    local proto addr port proc exposure
    while IFS=$'\t' read -r proto addr port proc exposure; do
      grep -qxF "$proto $addr $port $proc" "$run/ports-after" ||
        printf '%s\t%s\t%s\t%s\t%s\n' "$proto" "$addr" "$port" "$proc" "$exposure" >>"$closed"
    done <"$run/ports-before.exposure"
  fi

  tmp=$(mktemp "$(dirname "$file")/.gaia-report.XXXXXX") || return 1
  {
    printf '{\n'
    printf '  "schema": "gaia-report/1",\n'
    printf '  "gaia_version": %s,\n' "$(gaia_json_str "$GAIA_VERSION")"
    printf '  "dry_run": %s,\n' "$([[ $GAIA_DRY_RUN == 1 ]] && echo true || echo false)"
    printf '  "result": %s,\n' "$( ((failures == 0)) && echo '"success"' || echo '"failed"')"
    printf '  "failures": %d,\n' "$failures"
    printf '  "started_at": %s,\n' "$(gaia_json_str "$started_iso")"
    printf '  "finished_at": %s,\n' "$(gaia_json_str "$finished_iso")"
    printf '  "duration_s": %s,\n' "$(gaia__json_seconds $((finished_us - started_us)))"
    printf '  "system": {"os_id": %s, "os_version": %s, "os_codename": %s, "arch": %s, "hostname": %s},\n' \
      "$(gaia_json_str "${GAIA_OS_ID:-}")" "$(gaia_json_str "${GAIA_OS_VERSION:-}")" \
      "$(gaia_json_str "${GAIA_OS_CODENAME:-}")" "$(gaia_json_str "${GAIA_ARCH:-}")" "$(gaia_json_str "$host")"
    printf '  "config": {"admin_user": %s, "ssh_port": %s, "modules": %s, "firewall_allow": %s, "audit": %s},\n' \
      "$(gaia_json_str "${GAIA_ADMIN_USER:-}")" "$(gaia__json_num "$GAIA_SSH_PORT")" \
      "$(gaia__json_list -w "$GAIA_MODULES")" "$(gaia__json_list -w "$GAIA_FIREWALL_ALLOW")" \
      "$([[ $GAIA_AUDIT == 1 ]] && echo true || echo false)"
    printf '  "steps": ['
    for name in "${GAIA_STEPS[@]}"; do
      printf '%s\n    {"name": %s, "kind": %s, "status": %s, "duration_s": %s}' "$sep" \
        "$(gaia_json_str "$name")" "$(gaia_json_str "${GAIA_STEP_KIND[$name]}")" \
        "$(gaia_json_str "${GAIA__STATUS_OF[$name]:-skipped}")" "$(gaia__json_seconds "${GAIA__DURATION_US[$name]:-}")"
      sep=","
    done
    printf '\n  ],\n'
    printf '  "ports": {"before": %s, "after": %s, "closed": %s, "exposed_after": %s},\n' \
      "$(gaia__json_sockets "$run/ports-before.exposure")" "$(gaia__json_sockets "$run/ports-after.exposure")" \
      "$(gaia__json_sockets "$closed")" \
      "$(if [[ -f $run/ports-after.exposure ]]; then grep -c $'\tEXPOSED' "$run/ports-after.exposure" || true; else echo null; fi)"
    if [[ -n $before || -n $after ]]; then
      printf '  "lynis": {"before": %s, "after": %s, "gain": %s},\n' \
        "$(gaia__json_num "$before")" "$(gaia__json_num "$after")" "$gain"
    else
      printf '  "lynis": null,\n'
    fi
    printf '  "reboot_required": %s,\n' "$reboot"
    printf '  "warnings": %s,\n' "$(gaia__json_events "$run/events" warn)"
    printf '  "errors": %s,\n' "$(gaia__json_events "$run/events" error)"
    printf '  "next_steps": %s,\n' "$(gaia__json_list -l "$(cat "$run/next-steps" 2>/dev/null || true)")"
    printf '  "tips": %s,\n' "$(gaia__json_list -l "$(cat "$run/tips" 2>/dev/null || true)")"
    printf '  "log_file": %s\n' "$(gaia_json_str "${GAIA_LOG_FILE#"$GAIA_ROOT"}")"
    printf '}\n'
  } >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file"
}
