# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: Docker Engine + compose + buildx from the official repository, log rotation, and published ports filtered by ufw
#
# What this module guarantees, in order (each part acts only if needed):
#   1. distribution packages that conflict with Docker CE are removed (data in /var/lib/docker is kept);
#   2. the official repository, with its signing key checked by fingerprint (never docker.io or snap);
#   3. docker-ce, cli, containerd, buildx and compose plugins;
#   4. daemon.json MERGED with jq (other keys are kept): log rotation, live-restore, optional
#      data-root and localhost-only publishing;
#   5. the administrator in the docker group (optional; that group is equivalent to root);
#   6. ufw for containers: Docker writes its own iptables rules and published ports skip ufw. A rule
#      block in the DOCKER-USER chain (/etc/ufw/after.rules) makes ufw apply to them again: published
#      ports are reachable from the internet only through "ufw route allow" rules (GAIA_DOCKER_PUBLISH);
#   7. service enabled, and a "hello-world" smoke test.

GAIA_DOCKER_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88 # "Docker Release (CE deb)"
GAIA_DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
GAIA_DOCKER_LIST=/etc/apt/sources.list.d/docker.list
GAIA_DOCKER_DAEMON=/etc/docker/daemon.json
GAIA_DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
# From Docker's official documentation: distribution packages that conflict with Docker CE.
GAIA_DOCKER_CONFLICTS=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
GAIA_UFW_AFTER_RULES=/etc/ufw/after.rules

docker__daemon_json() {
  local real current='{}' wanted merged localhost=false
  [[ $GAIA_DOCKER_LOCALHOST_ONLY == 1 ]] && localhost=true
  real=$(gaia_path "$GAIA_DOCKER_DAEMON")
  if ! command -v jq >/dev/null 2>&1; then
    if gaia_is_dry_run; then
      gaia_warn "dry-run: jq not installed yet (the packages step installs it); daemon.json would be created or merged"
      gaia_mark_changed
      GAIA_CHANGED=1
      return 0
    fi
    gaia_fail "jq is not installed; run the packages step first"
  fi
  if [[ -s $real ]]; then
    jq -e 'type == "object"' "$real" >/dev/null 2>&1 ||
      gaia_fail "existing daemon.json is not a valid JSON object; fix it by hand (nothing was changed)" "file=$GAIA_DOCKER_DAEMON"
    current=$(jq -S . "$real")
  fi
  wanted=$(jq -n --arg ms "$GAIA_DOCKER_LOG_MAX_SIZE" --arg mf "$GAIA_DOCKER_LOG_MAX_FILE" \
    --arg dr "$GAIA_DOCKER_DATA_ROOT" --argjson localhost "$localhost" '
    {"log-driver": "json-file", "log-opts": {"max-size": $ms, "max-file": $mf}, "live-restore": true}
    + (if $dr != "" then {"data-root": $dr} else {} end)
    + (if $localhost then {"ip": "127.0.0.1"} else {} end)')
  # Recursive merge: keys that are not Gaia's (registry-mirrors, labels...) are kept as they are.
  merged=$(jq -S --argjson d "$wanted" '. * $d' <<<"$current")
  GAIA_CHANGED=0
  if [[ -s $real && $merged == "$current" ]]; then
    gaia_info "daemon.json already correct" "file=$GAIA_DOCKER_DAEMON"
    return 0
  fi
  if [[ -n $GAIA_DOCKER_DATA_ROOT ]] && [[ $(jq -r '."data-root" // ""' <<<"$current") != "$GAIA_DOCKER_DATA_ROOT" ]] &&
    [[ -d $(gaia_path /var/lib/docker/overlay2) ]]; then
    gaia_warn "new data-root: Docker does NOT move the data in /var/lib/docker; old images and volumes stay there" \
      "data_root=$GAIA_DOCKER_DATA_ROOT"
  fi
  gaia_ensure_file "$GAIA_DOCKER_DAEMON" 0644 "$merged"
}

# DOCKER-USER rules (same approach as the well-known ufw-docker project). Traffic between private
# networks is left alone; new connections from outside to containers are dropped unless a
# "ufw route allow" rule accepts them.
docker__ufw_block() {
  cat <<'EOF'
# BEGIN GAIA DOCKER-USER
# Managed by Gaia (docker module): makes ufw apply to ports published by Docker containers.
# Open a published port to the internet with: ufw route allow proto tcp from any to any port <port>
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END GAIA DOCKER-USER
EOF
}

docker__ufw_reload() {
  if gaia_ufw_active; then ufw reload; fi
}

# 0 if a "ufw route allow" rule for this port (and protocol) already exists.
docker__route_present() {
  local port=$1 proto=$2 line
  while IFS= read -r line; do
    [[ $line == "ufw route allow "* ]] || continue
    [[ " $line " == *" port $port "* || " $line " == *" $port/$proto "* ]] || continue
    [[ -z $proto || $line == *"proto $proto"* || $line == *"/$proto"* ]] && return 0
  done < <(ufw show added 2>/dev/null || true)
  return 1
}

docker__ufw() {
  if [[ $GAIA_DOCKER_UFW != 1 ]]; then
    gaia_warn "ufw integration disabled (GAIA_DOCKER_UFW=0): ports published by containers are reachable from the internet regardless of ufw"
    return 0
  fi
  local rules current new
  rules=$(gaia_path "$GAIA_UFW_AFTER_RULES")
  if [[ ! -f $rules ]]; then
    if gaia_is_dry_run; then
      gaia_warn "dry-run: $GAIA_UFW_AFTER_RULES does not exist yet (ufw is installed by the packages step); the DOCKER-USER rules would be added"
      gaia_mark_changed
      return 0
    fi
    gaia_warn "ufw is not installed ($GAIA_UFW_AFTER_RULES missing): published container ports are NOT filtered"
    return 0
  fi
  current=$(<"$rules")
  # Current content without Gaia's block, then the block at the end.
  new=$(awk '/^# BEGIN GAIA DOCKER-USER$/ { skip = 1 } !skip { print } /^# END GAIA DOCKER-USER$/ { skip = 0 }' <<<"$current")
  new=${new%$'\n'}
  new+=$'\n\n'"$(docker__ufw_block)"
  gaia_ensure_checked_file "$GAIA_UFW_AFTER_RULES" 0640 "$new" "ufw reload" docker__ufw_reload
  if ((GAIA_CHANGED)); then
    gaia_info "ufw now filters ports published by containers (DOCKER-USER chain)"
  else
    gaia_info "ufw already filters ports published by containers"
  fi

  local rule port proto
  for rule in $GAIA_DOCKER_PUBLISH; do
    port=${rule%%/*}
    proto=""
    [[ $rule == */* ]] && proto=${rule#*/}
    if docker__route_present "$port" "$proto"; then
      gaia_info "container port already open to the internet" "rule=$rule"
    elif [[ -n $proto ]]; then
      gaia_run ufw route allow proto "$proto" from any to any port "$port"
    else
      gaia_run ufw route allow from any to any port "$port"
    fi
  done
}

step_run() {
  local p
  local -a remove=() missing=()
  for p in "${GAIA_DOCKER_CONFLICTS[@]}"; do
    gaia_package_installed "$p" && remove+=("$p")
  done
  if ((${#remove[@]})); then
    gaia_warn "removing packages that conflict with the official Docker (data in /var/lib/docker is kept)" "packages=${remove[*]}"
    gaia_run apt-get "${GAIA_APT_OPTS[@]}" remove "${remove[@]}"
  else
    gaia_info "no conflicting package installed"
  fi

  gaia_ensure_repo_key "https://download.docker.com/linux/$GAIA_OS_ID/gpg" "$GAIA_DOCKER_KEYRING" "$GAIA_DOCKER_FPR" Docker
  gaia_ensure_file "$GAIA_DOCKER_LIST" 0644 \
    "deb [arch=$GAIA_ARCH signed-by=$GAIA_DOCKER_KEYRING] https://download.docker.com/linux/$GAIA_OS_ID $GAIA_OS_CODENAME stable"
  local list_changed=$GAIA_CHANGED

  for p in "${GAIA_DOCKER_PACKAGES[@]}"; do
    gaia_package_installed "$p" || missing+=("$p")
  done
  if ((${#missing[@]})); then
    gaia_apt_update force
    gaia_run apt-get "${GAIA_APT_OPTS[@]}" install "${missing[@]}"
  else
    if ((list_changed)); then gaia_apt_update force; fi
    gaia_info "Docker packages already installed"
  fi

  docker__daemon_json
  local daemon_changed=$GAIA_CHANGED

  if [[ -n $GAIA_ADMIN_USER && $GAIA_DOCKER_ADD_ADMIN_TO_GROUP == 1 ]]; then
    if gaia_user_in_group "$GAIA_ADMIN_USER" docker; then
      gaia_info "administrator already in the docker group" "user=$GAIA_ADMIN_USER"
    else
      gaia_run usermod -aG docker "$GAIA_ADMIN_USER"
      gaia_warn "the docker group is equivalent to root: its members control the whole server. Applies from the next login" "user=$GAIA_ADMIN_USER"
    fi
  fi

  if systemctl is-enabled --quiet docker 2>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    if ((daemon_changed)); then
      gaia_run systemctl restart docker
    else
      gaia_info "docker service already enabled and running"
    fi
  else
    gaia_run systemctl enable --now docker
  fi

  docker__ufw

  if gaia_is_dry_run; then
    gaia_info "[dry-run] 'docker run --rm hello-world' smoke test not run"
  elif [[ $GAIA_DOCKER_SMOKE_TEST != 1 ]]; then
    gaia_info "hello-world smoke test disabled (GAIA_DOCKER_SMOKE_TEST=0)"
  else
    local out
    out=$(docker run --rm hello-world 2>&1) || gaia_fail "docker run --rm hello-world failed: ${out##*$'\n'}"
    grep -q "Hello from Docker!" <<<"$out" || gaia_fail "hello-world ran but did not print the expected message"
    gaia_info "hello-world smoke test ok"
  fi
}
