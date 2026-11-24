# shellcheck shell=bash
# lib/ports.sh — listening sockets audit: what is listening, on which interface, and whether the
# firewall lets it through. Used at the start (preflight) and at the end (summary) of a run.

# One line per listening socket: "<proto> <address> <port> <process>", sorted and de-duplicated.
# Fails (status 1) when "ss" is not available.
gaia_ports_snapshot() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -tulpn 2>/dev/null | awk '
    {
      proto = $1; local_addr = $5; proc = "-"
      if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
      n = split(local_addr, parts, ":"); port = parts[n]
      addr = substr(local_addr, 1, length(local_addr) - length(port) - 1)
      gsub(/^\[|\]$/, "", addr); sub(/%.*/, "", addr)
      if (addr == "") addr = "*"
      print proto, addr, port, proc
    }' | sort -u
}

gaia_ports_is_loopback() {
  [[ $1 =~ ^127\. || $1 == "::1" || $1 == localhost || $1 =~ ^::ffff:127\. ]]
}

# 0 if a ufw "allow"/"limit" rule lets <proto> <port> in (simple port and range rules only).
gaia_ports_firewall_allows() {
  local proto=$1 port=$2 line from to p
  while IFS= read -r line; do
    [[ $line =~ ^ufw\ (allow|limit)\ ([0-9]+)(:([0-9]+))?(/(tcp|udp))?$ ]] || continue
    from=${BASH_REMATCH[2]}
    to=${BASH_REMATCH[4]:-$from}
    p=${BASH_REMATCH[6]:-any}
    [[ $p == any || $p == "$proto" ]] || continue
    ((port >= from && port <= to)) && return 0
  done < <(ufw show added 2>/dev/null || true)
  return 1
}

gaia_ports_docker_filtered() {
  grep -q '^# BEGIN GAIA DOCKER-USER' "$(gaia_path /etc/ufw/after.rules)" 2>/dev/null
}

# Logs every listening socket with its exposure. $1 = snapshot file, $2 = label (before/after).
# Sets GAIA_PORTS_EXPOSED to the number of sockets reachable from outside without a firewall rule.
gaia_ports_report() {
  local file=$1 label=$2 proto addr port proc exposure firewall_on=0 total=0
  GAIA_PORTS_EXPOSED=0
  gaia_ufw_active && firewall_on=1
  while read -r proto addr port proc; do
    [[ -n $proto ]] || continue
    total=$((total + 1))
    if gaia_ports_is_loopback "$addr"; then
      exposure="local only"
    elif [[ $proc == docker-proxy ]]; then
      if ((firewall_on)) && gaia_ports_docker_filtered; then
        exposure="docker, filtered by ufw route rules"
      else
        exposure="EXPOSED (Docker bypasses ufw)"
        GAIA_PORTS_EXPOSED=$((GAIA_PORTS_EXPOSED + 1))
      fi
    elif ((!firewall_on)); then
      exposure="EXPOSED (firewall inactive)"
      GAIA_PORTS_EXPOSED=$((GAIA_PORTS_EXPOSED + 1))
    elif gaia_ports_firewall_allows "$proto" "$port"; then
      exposure="public, allowed by firewall"
    else
      exposure="blocked by firewall"
    fi
    if [[ $exposure == EXPOSED* ]]; then
      gaia_warn "listening ($label)" "proto=$proto" "address=$addr" "port=$port" "process=$proc" "exposure=$exposure"
    else
      gaia_info "listening ($label)" "proto=$proto" "address=$addr" "port=$port" "process=$proc" "exposure=$exposure"
    fi
  done <"$file"
  gaia_info "listening sockets ($label)" "total=$total" "exposed=$GAIA_PORTS_EXPOSED" "firewall=$([[ $firewall_on == 1 ]] && echo active || echo inactive)"
}
