#!/usr/bin/env bash
# Integration test: a REAL Gaia run inside a throwaway Ubuntu/Debian container, as root.
#
#   docker run --rm --cap-add NET_ADMIN -v "$PWD:/gaia-src:ro" ubuntu:24.04 bash /gaia-src/tests/integration/run.sh
#
# Containers have no systemd, so systemctl, timedatectl and hostnamectl are replaced by small
# stand-ins (/usr/local/bin) that keep their state in files. Everything else is real: apt, users,
# sudoers, sshd -t/-T, ufw (needs NET_ADMIN), fail2ban-client -t, sysctl files, unattended-upgrades.
#
# Checks: dry-run changes nothing; the first run succeeds; the second run changes nothing (every step
# "ok", "skipped" or "not selected"); and the resulting configuration is the expected one.
set -Eeuo pipefail

SRC=${1:-/gaia-src}
WORK=/tmp/gaia
FAKE_STATE=/run/fake-systemd
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n=== %s\n' "$*"; }
fail() {
  echo "INTEGRATION FAILED: $*" >&2
  exit 1
}

step "preparing the container"
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends ca-certificates openssh-server openssh-client iproute2 procps >/dev/null
rm -rf "$WORK"
cp -a "$SRC" "$WORK"
mkdir -p /run/sshd "$FAKE_STATE"
ssh-keygen -A >/dev/null

cat >/usr/local/bin/systemctl <<'EOF'
#!/usr/bin/env bash
# systemctl stand-in for containers: enable/disable/start/stop tracked in /run/fake-systemd.
state=/run/fake-systemd
args=()
for a in "$@"; do [[ $a == --* && $a != --now ]] || args+=("$a"); done
set -- "${args[@]}"
cmd=${1:-}; shift || true
now=0; [[ ${1:-} == --now ]] && { now=1; shift; }
unit=${1:-}; unit=${unit%.service}
case $cmd in
  is-active) [[ -e $state/$unit.active ]] ;;
  is-enabled) [[ -e $state/$unit.enabled ]] ;;
  enable) touch "$state/$unit.enabled"; ((now)) && touch "$state/$unit.active"; exit 0 ;;
  disable) rm -f "$state/$unit.enabled"; ((now)) && rm -f "$state/$unit.active"; exit 0 ;;
  start|restart|reload|try-restart) touch "$state/$unit.active" ;;
  stop) rm -f "$state/$unit.active" ;;
  *) exit 0 ;;
esac
EOF

cat >/usr/local/bin/timedatectl <<'EOF'
#!/usr/bin/env bash
# timedatectl stand-in for containers: /etc/localtime and a file for NTP.
case "$*" in
  "show -p Timezone --value") t=$(readlink /etc/localtime 2>/dev/null); echo "${t#*/zoneinfo/}" ;;
  "show -p NTP --value") [[ -e /run/fake-systemd/ntp ]] && echo yes || echo no ;;
  "set-ntp true") touch /run/fake-systemd/ntp ;;
  set-timezone\ *) ln -sfn "/usr/share/zoneinfo/$2" /etc/localtime; echo "$2" >/etc/timezone ;;
  list-timezones) cd /usr/share/zoneinfo && find . -type f | sed 's|^\./||' | sort ;;
  *) exit 0 ;;
esac
EOF

cat >/usr/local/bin/hostnamectl <<'EOF'
#!/usr/bin/env bash
# hostnamectl stand-in for containers.
if [[ ${1:-} == set-hostname ]]; then echo "$2" >/etc/hostname; else echo "Static hostname: $(cat /etc/hostname)"; fi
EOF
chmod +x /usr/local/bin/{systemctl,timedatectl,hostnamectl}

ssh-keygen -t ed25519 -N '' -C ci@integration -f /tmp/ci-key -q
cat >"$WORK/gaia.conf" <<EOF
GAIA_ADMIN_USER=ci
GAIA_ADMIN_SSH_KEYS="$(cat /tmp/ci-key.pub)"
GAIA_REQUIRE_SYSTEMD=0
GAIA_CHECK_INTERNET=0
GAIA_TIMEZONE=America/Sao_Paulo
GAIA_FIREWALL_ALLOW="80/tcp 443/tcp"
GAIA_DIRS="/srv/apps:@admin:@admin:0755"
EOF
chmod 600 "$WORK/gaia.conf"
# The hostname step is left out: Docker bind-mounts /etc/hostname and /etc/hosts, which cannot be
# replaced atomically inside a container (it is covered by the bats suite instead).
run_gaia() { bash "$WORK/bootstrap.sh" --config "$WORK/gaia.conf" --modules none --no-audit --skip hostname --yes "$@"; }

step "dry-run on a fresh container"
before=$(find /etc -xdev -type f -newer /tmp/ci-key 2>/dev/null | sort)
run_gaia --dry-run | tee /tmp/gaia-dry.log
after=$(find /etc -xdev -type f -newer /tmp/ci-key 2>/dev/null | sort)
[[ $before == "$after" ]] || fail "dry-run changed files in /etc: $(comm -13 <(echo "$before") <(echo "$after"))"
getent passwd ci >/dev/null && fail "dry-run created the admin user"

step "first real run"
run_gaia | tee /tmp/gaia-run1.log || fail "first run failed"

step "second real run (must change nothing)"
run_gaia | tee /tmp/gaia-run2.log || fail "second run failed"
if grep -E '^\[gaia\]\[info\]\[step=main\] \| [a-z:-]+ +\| (done|failed) ' /tmp/gaia-run2.log; then
  fail "the second run changed something (steps above)"
fi

step "checking the result"
id ci | grep -q '(sudo)' || fail "ci is not in the sudo group"
[[ $(stat -c '%a %U' /home/ci/.ssh/authorized_keys) == "600 ci" ]] || fail "authorized_keys mode/owner"
grep -qF "$(cut -d' ' -f2 /tmp/ci-key.pub)" /home/ci/.ssh/authorized_keys || fail "key not installed"
sshd -t || fail "sshd -t rejects the final configuration"
effective=$(sshd -T -C user=ci,host=localhost,addr=127.0.0.1)
grep -qx 'permitrootlogin no' <<<"$effective" || fail "root login still allowed"
grep -qx 'passwordauthentication no' <<<"$effective" || fail "password login still allowed"
grep -qx 'allowusers ci' <<<"$effective" || fail "AllowUsers is not ci"
ufw status | grep -q '^Status: active' || fail "ufw is not active"
ufw status | grep -Eq '^22/tcp +LIMIT' || fail "SSH is not rate-limited in ufw"
ufw status | grep -Eq '^443/tcp +ALLOW' || fail "443/tcp not allowed"
fail2ban-client -t >/dev/null || fail "fail2ban configuration rejected"
[[ $(readlink /etc/localtime) == */America/Sao_Paulo ]] || fail "time zone not set"
[[ -f /etc/apt/apt.conf.d/52gaia-unattended-upgrades ]] || fail "unattended-upgrades not configured"
[[ -f /etc/systemd/journald.conf.d/90-gaia.conf ]] || fail "journald limits missing"
[[ $(stat -c '%a %U' /srv/apps) == "755 ci" ]] || fail "/srv/apps mode/owner"
grep -q 'listening sockets' /tmp/gaia-run1.log || fail "no listening-port report"

echo
echo "INTEGRATION OK ($(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release))"
