#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# skills/gaia/scripts/gaia-remote.sh (the /gaia agent skill helper), with a fake ssh: argument
# checks, quoting of the options sent to the server, report copy and the verify checks.

load test_helper

HELPER="$BATS_TEST_DIRNAME/../skills/gaia/scripts/gaia-remote.sh"

setup_extra() {
  export FAKE_DIR=$BATS_TEST_TMPDIR/fakessh HOME=$BATS_TEST_TMPDIR/home
  mkdir -p "$FAKE_DIR" "$HOME"
  # Fake ssh: logs every call; answers by remote command and mode (FAKE_MODE=good|bad).
  cat >"$SHIMS/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/ssh.log"
case " $* " in *" -O check "*) exit 1 ;; *" -O exit "*) exit 0 ;; *" -fN "*) exit 0 ;; esac
target="" last=${*: -1}
for a in "$@"; do [[ $a =~ ^[A-Za-z0-9._-]+@ ]] && target=$a; done
host=${target#*@}
case $last in
  "id -u") echo 0 ;;
  "sudo -n true") exit 0 ;;
  *"test -x "*) exit 0 ;;
  "pgrep "*) exit 1 ;;
  *"bash -s") n=$(find "$FAKE_DIR" -name 'stdin.*' | wc -l); cat >"$FAKE_DIR/stdin.$n" ;;
  *"cat /var/lib/gaia/agent-run.rc") echo "${FAKE_RC:-0}" ;;
  *"cat /var/lib/gaia/agent-report.json") echo '{"schema":"gaia-report/1","result":"success"}' ;;
  *'id -un'*)
    [[ ${FAKE_MODE:-good} == good ]] && { echo "${target%@*} sudo-ok"; exit 0; }
    echo "${target%@*} sudo-no" ;;
  true)
    if [[ " $* " == *PubkeyAuthentication=no* ]]; then
      if [[ ${FAKE_MODE:-good} == good ]]; then echo "$target: Permission denied (publickey)." >&2; else echo "$target: Permission denied (publickey,password)." >&2; fi
      exit 255
    fi
    if [[ ${FAKE_MODE:-good} == good ]]; then echo "$target: Permission denied (publickey)." >&2; exit 255; fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SHIMS/ssh"
}

@test "--help prints the usage; bad targets, ports and options are refused" {
  run bash "$HELPER" --help
  assert_success
  assert_output --partial 'gaia-remote.sh verify <admin@host>'
  run bash "$HELPER" check not-a-target
  assert_failure
  assert_output --partial 'expected user@host'
  run bash "$HELPER" check root@203.0.113.10 -p 99x
  assert_failure
  assert_output --partial 'invalid port'
  run bash "$HELPER" run root@203.0.113.10 -- --report-json /tmp/x.json
  assert_failure
  assert_output --partial 'do not pass --report-json'
}

@test "run: options with spaces reach the server shell-quoted, detached, and the report comes back" {
  cd "$BATS_TEST_TMPDIR"
  run bash "$HELPER" run root@203.0.113.10 -p 2222 --report out.json -- \
    --admin-user ops --ssh-key 'ssh-ed25519 AAAAC3Nz me@laptop' --modules docker
  assert_success
  assert_output --partial 'report copied to out.json'
  assert_output --partial 'Gaia finished with exit code 0'
  run jq -r .result "$BATS_TEST_TMPDIR/out.json"
  assert_output success
  # The job script sent to the server: valid bash, quoted key, detached with setsid/nohup.
  run cat "$FAKE_DIR/stdin.0"
  assert_output --partial '/opt/gaia/current/bootstrap.sh --yes --report-json /var/lib/gaia/agent-report.json --admin-user ops --ssh-key ssh-ed25519\ AAAAC3Nz\ me@laptop --modules docker'
  assert_output --partial 'nohup setsid bash /var/lib/gaia/agent-run.sh'
  run bash -n "$FAKE_DIR/stdin.0"
  assert_success
  run grep -c -- '-p 2222' "$FAKE_DIR/ssh.log"
  refute_output 0
}

@test "run: Gaia's exit code is passed on" {
  cd "$BATS_TEST_TMPDIR"
  FAKE_RC=1 run bash "$HELPER" run root@203.0.113.10 -- --dry-run
  assert_failure 1
  assert_output --partial 'Gaia finished with exit code 1'
}

@test "verify: new connections, all checks pass when only the admin key gets in" {
  run bash "$HELPER" verify ops@203.0.113.10 --old-user root
  assert_success
  assert_output --regexp 'login as ops with your key +PASS'
  assert_output --regexp 'sudo without a password +PASS'
  assert_output --regexp 'login as root refused +PASS'
  assert_output --regexp 'password logins refused +PASS'
  # Never through the master connection.
  run grep -c 'ControlPath=none' "$FAKE_DIR/ssh.log"
  assert_output 3
}

@test "verify: fails loudly when root still logs in or passwords are offered" {
  FAKE_MODE=bad run bash "$HELPER" verify ops@203.0.113.10 --old-user root
  assert_failure
  assert_output --regexp 'login as root refused +FAIL'
  assert_output --regexp 'password logins refused +FAIL'
  assert_output --regexp 'sudo without a password +FAIL'
  assert_output --partial 'keep the master connection open'
}
