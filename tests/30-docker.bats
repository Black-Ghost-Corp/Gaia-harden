#!/usr/bin/env bats
# docker module: official repository, conflicts, merged daemon.json, group, service, ufw for containers.

load test_helper

DJ=/etc/docker/daemon.json
AFTER=/etc/ufw/after.rules

docker_ready() {
  existing_admin
  installed_packages jq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  echo docker >>"$STUB_STATE/groups"
  echo "admin sudo docker" >"$STUB_STATE/users/admin"
  active_unit docker
  mkdir -p "$FAKE_ROOT/etc/apt/keyrings"
  echo FAKE-GPG-KEY-DOCKER >"$FAKE_ROOT/etc/apt/keyrings/docker.asc"
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" >"$FAKE_ROOT/etc/apt/sources.list.d/docker.list"
}

@test "fresh machine: verified key, official repository, packages, service and hello-world" {
  existing_admin
  gaia --only docker
  assert_success
  assert_called '^curl -fsSL .*https://download.docker.com/linux/ubuntu/gpg'
  assert_output --regexp 'warn.*docker group is equivalent to root'
  [[ -f $FAKE_ROOT/etc/apt/keyrings/docker.asc ]]
  run cat "$FAKE_ROOT/etc/apt/sources.list.d/docker.list"
  assert_output "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable"
  assert_called '^apt-get .*install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'
  refute_called 'install .*docker\.io'
  assert_called '^systemctl enable --now docker$'
  assert_called '^usermod -aG docker admin$'
  assert_called '^docker run --rm hello-world$'
}

@test "a GPG key with the wrong fingerprint aborts without installing the repository" {
  existing_admin
  echo "WRONG-KEY" >"$STUB_STATE/docker_key"
  gaia --only docker
  assert_failure
  assert_output --partial 'expected fingerprint'
  [[ ! -e $FAKE_ROOT/etc/apt/keyrings/docker.asc ]]
  [[ ! -e $FAKE_ROOT/etc/apt/sources.list.d/docker.list ]]
}

@test "removes conflicting packages only if they are installed" {
  existing_admin
  installed_packages docker.io runc
  gaia --only docker
  assert_success
  assert_called '^apt-get .*remove docker.io runc$'
  refute_called 'remove .*podman-docker'
}

@test "a new daemon.json has log rotation and live-restore" {
  docker_ready
  conf GAIA_DOCKER_LOG_MAX_SIZE=20m GAIA_DOCKER_LOG_MAX_FILE=5
  gaia --only docker
  assert_success
  run jq -c . "$FAKE_ROOT$DJ"
  assert_output '{"live-restore":true,"log-driver":"json-file","log-opts":{"max-file":"5","max-size":"20m"}}'
}

@test "an existing daemon.json is merged, keeping foreign keys, and docker restarts once" {
  docker_ready
  mkdir -p "$FAKE_ROOT/etc/docker"
  echo '{"registry-mirrors":["https://mirror.example"],"log-opts":{"labels":"app"},"live-restore":false}' >"$FAKE_ROOT$DJ"
  gaia --only docker
  assert_success
  run jq -c . "$FAKE_ROOT$DJ"
  assert_output '{"live-restore":true,"log-driver":"json-file","log-opts":{"labels":"app","max-file":"3","max-size":"10m"},"registry-mirrors":["https://mirror.example"]}'
  run grep -c '^systemctl restart docker$' "$STUB_STATE/calls.log"
  assert_output 1
}

@test "an invalid daemon.json fails without being overwritten" {
  docker_ready
  mkdir -p "$FAKE_ROOT/etc/docker"
  echo '{ this is not json' >"$FAKE_ROOT$DJ"
  gaia --only docker
  assert_failure
  assert_output --partial 'daemon.json'
  run cat "$FAKE_ROOT$DJ"
  assert_output '{ this is not json'
}

@test "data-root and localhost-only publishing go into daemon.json when asked" {
  docker_ready
  conf GAIA_DOCKER_DATA_ROOT=/srv/docker GAIA_DOCKER_LOCALHOST_ONLY=1
  gaia --only docker
  assert_success
  run jq -r '."data-root" + " " + .ip' "$FAKE_ROOT$DJ"
  assert_output '/srv/docker 127.0.0.1'
}

@test "ufw for containers: DOCKER-USER block appended to after.rules and ufw reloaded" {
  docker_ready
  touch "$STUB_STATE/ufw/active"
  gaia --only docker
  assert_success
  assert_output --partial 'ufw now filters ports published by containers'
  run cat "$FAKE_ROOT$AFTER"
  assert_line --index 0 '*filter'
  assert_line '# BEGIN GAIA DOCKER-USER'
  assert_line '-A DOCKER-USER -j ufw-user-forward'
  assert_line '-A ufw-docker-logging-deny -j DROP'
  assert_line '# END GAIA DOCKER-USER'
  assert_called '^ufw reload$'
}

@test "ufw for containers: the block is replaced, never duplicated" {
  docker_ready
  gaia --only docker
  gaia --only docker
  assert_success
  assert_status docker ok
  run grep -c '^# BEGIN GAIA DOCKER-USER$' "$FAKE_ROOT$AFTER"
  assert_output 1
}

@test "ufw for containers: GAIA_DOCKER_PUBLISH opens container ports with route rules" {
  docker_ready
  conf 'GAIA_DOCKER_PUBLISH="80/tcp 443/tcp"'
  gaia --only docker
  assert_success
  assert_called '^ufw route allow proto tcp from any to any port 80$'
  assert_called '^ufw route allow proto tcp from any to any port 443$'
  clear_calls
  gaia --only docker
  refute_called '^ufw route'
}

@test "ufw for containers: a failed ufw reload restores after.rules" {
  docker_ready
  touch "$STUB_STATE/ufw/active"
  local before
  before=$(cat "$FAKE_ROOT$AFTER")
  force_failure ufw_reload 1
  gaia --only docker
  assert_failure
  [[ $(cat "$FAKE_ROOT$AFTER") == "$before" ]]
}

@test "GAIA_DOCKER_UFW=0 warns that published ports bypass ufw" {
  docker_ready
  conf GAIA_DOCKER_UFW=0
  gaia --only docker
  assert_success
  assert_output --regexp 'warn.*regardless of ufw'
  run grep -c 'GAIA DOCKER-USER' "$FAKE_ROOT$AFTER"
  assert_output 0
}

@test "second run changes nothing" {
  existing_admin
  conf GAIA_DOCKER_SMOKE_TEST=0
  installed_packages jq
  gaia --only docker
  assert_success
  clear_calls
  gaia --only docker
  assert_success
  assert_no_mutation
  assert_status docker ok
}

@test "GAIA_DOCKER_SMOKE_TEST=0 does not run hello-world" {
  docker_ready
  conf GAIA_DOCKER_SMOKE_TEST=0
  gaia --only docker
  assert_success
  refute_called '^docker run'
}

@test "dry-run: no change and no hello-world" {
  existing_admin
  gaia --dry-run --only docker
  assert_success
  assert_no_mutation
  refute_called '^docker run'
  [[ ! -e $FAKE_ROOT/etc/apt/keyrings/docker.asc ]]
  [[ ! -e $FAKE_ROOT$DJ ]]
}

@test "the final audit tells docker ports apart (filtered vs exposed)" {
  docker_ready
  touch "$STUB_STATE/ufw/active"
  printf '%s\n' 'tcp LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:* users:(("docker-proxy",pid=9,fd=4))' >"$STUB_STATE/ss"
  gaia --only summary
  assert_output --regexp 'port=8080 process=docker-proxy exposure="EXPOSED \(Docker bypasses ufw\)"'
  gaia --only docker,summary
  assert_output --regexp 'port=8080 process=docker-proxy exposure="docker, filtered by ufw route rules"'
}
