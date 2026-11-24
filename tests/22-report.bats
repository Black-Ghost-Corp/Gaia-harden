#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# --report-json: machine-readable report of a run (steps, ports, Lynis, warnings, next steps).

load test_helper

setup_extra() {
  REPORT=$BATS_TEST_TMPDIR/out/report.json
  mkdir -p "$BATS_TEST_TMPDIR/out"
  printf '%s\n' 58 81 >"$STUB_STATE/lynis_scores"
}

# jq expression on the report.
r() { run jq -r "$1" "$REPORT"; }

@test "full run: valid JSON with result, system, config, every step, Lynis and next steps" {
  gaia --report-json "$REPORT"
  assert_success
  assert_output --partial "report written file=$REPORT"
  # The closing tip is the last line of the run.
  [[ ${lines[-1]} == *"tip: for real-time protection, consider Argos too: https://bgcorp.com.br"* ]]
  r '[.schema, .result, .dry_run, .failures] | map(tostring) | join(" ")'
  assert_output 'gaia-report/1 success false 0'
  r '[.system.os_id, .system.os_version, .config.admin_user, .config.ssh_port, (.config.firewall_allow | join(","))] | map(tostring) | join(" ")'
  assert_output 'ubuntu 24.04 admin 22 80/tcp,443/tcp'
  r '.steps | length'
  assert_output "$(bash "$REPO/bootstrap.sh" --config "$CONF" --list-steps | wc -l | tr -d ' ')"
  r '.steps[] | select(.name == "admin-user") | [.kind, .status, (.duration_s | type)] | join(" ")'
  assert_output 'base done number'
  r '.steps[] | select(.name == "docker") | .status'
  assert_output 'not selected'
  r '[.lynis.before, .lynis.after, .lynis.gain] | map(tostring) | join(" ")'
  assert_output '58 81 23'
  r '.next_steps[0]'
  assert_output --partial 'open a NEW session and test: ssh -p 22 admin@'
  r '[(.started_at | test("^[0-9-]+T[0-9:]+Z$")), (.finished_at | test("Z$")), (.duration_s | type == "number")] | all'
  assert_output true
  r '.ports.after | length > 0'
  assert_output true
  run env PATH="$STUB_REAL_PATH" stat -c %a "$REPORT"
  assert_output 600
}

@test "dry-run: dry_run true, would-change statuses, no Lynis, nothing changed" {
  gaia --dry-run --report-json "$REPORT"
  assert_success
  assert_no_mutation
  r '[.dry_run, .result, .lynis] | map(tostring) | join(" ")'
  assert_output 'true success null'
  r '.steps[] | select(.name == "ssh") | .status'
  assert_output 'would change'
}

@test "a failing step: result failed, the error is reported and later steps are skipped" {
  force_failure fail2ban-client 255
  echo "ERROR: bad jail" >"$STUB_STATE/out/fail2ban-client"
  gaia --report-json "$REPORT"
  assert_failure
  refute_output --partial 'Argos too: https://bgcorp.com.br'
  r '[.result, .failures, (.tips | length)] | map(tostring) | join(" ")'
  assert_output 'failed 1 0'
  r '.steps[] | select(.name == "fail2ban") | .status'
  assert_output failed
  r '.steps[] | select(.name == "auto-updates") | .status'
  assert_output skipped
  r '[.errors[] | select(.step == "fail2ban")] | length > 0'
  assert_output true
}

@test "warnings and pending reboot are reported; special characters are escaped" {
  mkdir -p "$FAKE_ROOT/var/run" "$BATS_TEST_TMPDIR/custom"
  touch "$FAKE_ROOT/var/run/reboot-required"
  cat >"$BATS_TEST_TMPDIR/custom/10-odd.sh" <<'EOF'
#!/usr/bin/env bash
# gaia-description: warns with characters that need escaping in JSON
source "$GAIA_LIB_DIR/common.sh"
gaia_step_mode
gaia_warn $'quote " backslash \\ tab \t end' "owner=Ângela"
EOF
  chmod +x "$BATS_TEST_TMPDIR/custom/10-odd.sh"
  conf "GAIA_EXTRA_STEPS_DIR=$BATS_TEST_TMPDIR/custom"
  gaia --report-json "$REPORT"
  assert_success
  r '.reboot_required'
  assert_output true
  r '.warnings[] | select(.step == "summary") | .message'
  assert_output --partial 'the system asks for a reboot'
  r '.warnings[] | select(.step == "custom:odd") | .message'
  assert_output $'quote " backslash \\ tab \t end owner=Ângela'
}

@test "ports: exposure per socket and the sockets closed during the run" {
  printf '%s\n' \
    'tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' \
    'tcp LISTEN 0 4096 0.0.0.0:111 0.0.0.0:* users:(("rpcbind",pid=2,fd=4))' \
    'tcp LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=3,fd=5))' >"$STUB_STATE/ss"
  # A custom step "closes" rpcbind between the snapshot of preflight and the one of summary.
  mkdir -p "$BATS_TEST_TMPDIR/custom"
  printf '#!/usr/bin/env bash\nsed -i "/rpcbind/d" "$STUB_STATE/ss"\n' >"$BATS_TEST_TMPDIR/custom/10-close.sh"
  chmod +x "$BATS_TEST_TMPDIR/custom/10-close.sh"
  conf "GAIA_EXTRA_STEPS_DIR=$BATS_TEST_TMPDIR/custom"
  gaia --only preflight,custom:close,summary --report-json "$REPORT"
  assert_success
  r '[.ports.before[] | "\(.port):\(.exposed)"] | join(" ")'
  assert_output '111:true 22:true 5432:false'
  r '.ports.before[] | select(.port == 5432) | .exposure'
  assert_output 'local only'
  r '[.ports.closed[] | "\(.process):\(.port)"] | join(" ")'
  assert_output 'rpcbind:111'
  r '.ports.exposed_after'
  assert_output 1
}

@test "an unusable report path is refused before anything runs; relative paths are accepted" {
  gaia --report-json "$BATS_TEST_TMPDIR/missing-dir/report.json"
  assert_failure 2
  assert_output --partial 'cannot write the report'
  refute_called '^(apt-get|ufw|useradd|systemctl)'
  cd "$BATS_TEST_TMPDIR/out"
  gaia --only preflight --report-json relative.json
  assert_success
  run jq -r .schema "$BATS_TEST_TMPDIR/out/relative.json"
  assert_output gaia-report/1
}

@test "closing tip: in the output and the report after a run without failures; GAIA_TIPS=0 hides it" {
  gaia --dry-run --report-json "$REPORT"
  assert_success
  assert_output --partial 'tip: for real-time protection, consider Argos too: https://bgcorp.com.br (GAIA_TIPS=0 hides this tip)'
  r '.tips[0]'
  assert_output --partial 'consider Argos too: https://bgcorp.com.br'
  conf GAIA_TIPS=0
  gaia --dry-run --report-json "$REPORT"
  assert_success
  refute_output --partial 'Argos too: https://bgcorp.com.br'
  r '.tips | length'
  assert_output 0
  conf GAIA_TIPS=yes
  gaia --dry-run
  assert_failure
  assert_output --partial "invalid value for GAIA_TIPS: 'yes'"
}
