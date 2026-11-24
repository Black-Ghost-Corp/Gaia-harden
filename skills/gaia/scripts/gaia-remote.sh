#!/usr/bin/env bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-remote.sh — runs Gaia Harden on a remote server over SSH, for the /gaia agent skill (and for
# humans). It never handles passwords or private keys: SSH authenticates with the caller's own
# ssh-agent / ~/.ssh configuration, in BatchMode (no prompts).
#
#   gaia-remote.sh open   <user@host> [-p PORT]            keep a master SSH connection (safety net)
#   gaia-remote.sh check  <user@host> [-p PORT]            system, privileges, keys, existing Gaia
#   gaia-remote.sh fetch  <user@host> [-p PORT] [--ref REF | --local DIR]
#                                                          put Gaia in /opt/gaia/current on the server
#   gaia-remote.sh run    <user@host> [-p PORT] [--report FILE] -- <bootstrap.sh options>
#                                                          run Gaia (detached on the server), stream the
#                                                          output and copy the JSON report back
#   gaia-remote.sh attach <user@host> [-p PORT] [--report FILE]
#                                                          follow a run again after a dropped connection
#   gaia-remote.sh verify <admin@host> [-p PORT] [--old-user USER]
#                                                          NEW session as the administrator: login, sudo,
#                                                          old user and passwords refused
#   gaia-remote.sh close  <user@host> [-p PORT]            close the master connection
#
# Environment: GAIA_REPO (default Black-Ghost-Corp/gaia-harden), GAIA_SSH_OPTS (extra ssh options).
set -Eeuo pipefail

REPO=${GAIA_REPO:-Black-Ghost-Corp/gaia-harden}
REMOTE_DIR=/opt/gaia
REMOTE_REPORT=/var/lib/gaia/agent-report.json
REMOTE_OUT=/var/log/gaia/agent-run.out
REMOTE_RC=/var/lib/gaia/agent-run.rc

die() {
  echo "[gaia-remote] error: $*" >&2
  exit 1
}
info() { echo "[gaia-remote] $*" >&2; }

# Prints the header comment (from the "gaia-remote.sh —" line to the line before "set -E...").
usage() {
  sed -n '/^# gaia-remote.sh /,/^set -E/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  exit "${1:-2}"
}

# ---------------------------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------------------------
CMD=${1:-}
case $CMD in
  -h | --help | help) usage 0 ;;
  "") usage >&2 ;;
esac
shift
TARGET=${1:-}
[[ $TARGET =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+$ ]] || die "expected user@host as the second argument, got '${TARGET}'"
shift
HOST=${TARGET#*@}
USER_=${TARGET%@*}
PORT=22 REF="" LOCAL="" REPORT="" OLD_USER=root
declare -a REST=()
while (($#)); do
  case $1 in
    -p | --port) PORT=${2:?-p needs a port}; shift ;;
    --ref) REF=${2:?--ref needs a branch or tag}; shift ;;
    --local) LOCAL=${2:?--local needs a directory}; shift ;;
    --report) REPORT=${2:?--report needs a file}; shift ;;
    --old-user) OLD_USER=${2:?--old-user needs a user}; shift ;;
    --) shift; REST=("$@"); break ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ $PORT =~ ^[0-9]{1,5}$ ]] || die "invalid port: $PORT"
[[ -z $REF || $REF =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid --ref: $REF"
REPORT=${REPORT:-./gaia-report-$HOST.json}

# The master connection is shared by every command (ControlPath) when it exists. "verify" never
# uses it: it must prove that a brand-new login works.
CONTROL=${HOME}/.ssh/gaia-%r@%h-%p
# shellcheck disable=SC2206 # GAIA_SSH_OPTS is a list of options on purpose.
SSH_BASE=(ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 ${GAIA_SSH_OPTS:-})
SSH=("${SSH_BASE[@]}" -o ControlMaster=auto -o "ControlPath=$CONTROL" -o ControlPersist=60m)

remote() { "${SSH[@]}" "$TARGET" "$@"; }

# Shell prefix that gives root on the server: nothing for root, "sudo -n" otherwise (never a password).
remote_sudo_prefix() {
  local uid
  uid=$(remote 'id -u') || die "SSH to $TARGET failed (check the address, port and that your key is loaded in ssh-agent)"
  if [[ $uid == 0 ]]; then
    printf ''
  elif remote 'sudo -n true' >/dev/null 2>&1; then
    printf 'sudo -n '
  else
    die "$USER_ is not root and 'sudo -n' asks for a password. Connect as root, or give $USER_ passwordless sudo; this tool never handles passwords."
  fi
}

# ---------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------
cmd_open() {
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  if "${SSH[@]}" -O check "$TARGET" >/dev/null 2>&1; then
    info "master connection already open to $TARGET:$PORT"
  elif "${SSH[@]}" -fN "$TARGET" 2>/dev/null && "${SSH[@]}" -O check "$TARGET" >/dev/null 2>&1; then
    info "master connection open to $TARGET:$PORT (kept for 60 minutes; it stays usable even if new logins break)"
  else
    info "WARNING: could not keep a master connection (unsupported by this ssh, e.g. Windows OpenSSH)."
    info "WARNING: open your OWN terminal session to $TARGET now and keep it open until 'verify' passes."
  fi
}

cmd_close() {
  "${SSH[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true
  info "master connection closed"
}

cmd_check() {
  local sudo
  sudo=$(remote_sudo_prefix)
  remote "SUDO='$sudo' bash -s" <<'EOF'
. /etc/os-release 2>/dev/null || true
echo "system:      ${PRETTY_NAME:-unknown} ($(uname -m))"
echo "login user:  $(id -un) (uid $(id -u))"
echo "privileges:  ${SUDO:-root}"
echo "hostname:    $(hostname)"
echo "bash:        ${BASH_VERSION}"
echo "systemd:     $([ -d /run/systemd/system ] && echo yes || echo no)"
[ "$(id -u)" = 0 ] || echo "keys of $(id -un): $(cat ~/.ssh/authorized_keys 2>/dev/null | grep -cE '^[^#]*(ssh-|ecdsa-|sk-)')"
echo "keys of root:$($SUDO cat /root/.ssh/authorized_keys 2>/dev/null | grep -cE '^[^#]*(ssh-|ecdsa-|sk-)')"
echo "listening:   $($SUDO ss -H -tuln 2>/dev/null | awk '{print $1"/"$5}' | sort -u | tr '\n' ' ')"
if [ -x /opt/gaia/current/bootstrap.sh ]; then echo "gaia:        $(/opt/gaia/current/bootstrap.sh --version)"; else echo "gaia:        not installed"; fi
EOF
}

cmd_fetch() {
  local sudo
  sudo=$(remote_sudo_prefix)
  if [[ -n $LOCAL ]]; then
    [[ -x $LOCAL/bootstrap.sh ]] || die "--local $LOCAL is not a Gaia checkout (bootstrap.sh missing)"
    info "copying the local checkout $LOCAL to $REMOTE_DIR/src on $HOST"
    tar -C "$LOCAL" --exclude=.git -czf - . |
      remote "${sudo}rm -rf $REMOTE_DIR/src && ${sudo}mkdir -p $REMOTE_DIR/src && ${sudo}tar -xzf - -C $REMOTE_DIR/src --no-same-owner && ${sudo}ln -sfn $REMOTE_DIR/src $REMOTE_DIR/current"
  else
    remote "SUDO='$sudo' REPO='$REPO' REF='$REF' DIR='$REMOTE_DIR' bash -s" <<'EOF'
set -e
url=https://github.com/$REPO
# Preferred: a signed release, verified by its installer before anything is installed.
if [ -z "$REF" ] && curl -fsIL --max-time 30 "$url/releases/latest/download/install.sh" >/dev/null 2>&1; then
  tmp=$(mktemp)
  curl -fsSL --proto '=https' --max-time 120 -o "$tmp" "$url/releases/latest/download/install.sh"
  $SUDO bash "$tmp" --download-only --dir "$DIR"
  rm -f "$tmp"
else
  # No published release (or a specific ref asked): shallow clone.
  command -v git >/dev/null 2>&1 || { $SUDO apt-get update -qq && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null; }
  $SUDO rm -rf "$DIR/src"
  $SUDO mkdir -p "$DIR"
  $SUDO git clone --quiet --depth 1 ${REF:+--branch "$REF"} "$url.git" "$DIR/src"
  $SUDO ln -sfn "$DIR/src" "$DIR/current"
fi
echo "gaia ready: $($DIR/current/bootstrap.sh --version) in $DIR/current"
EOF
  fi
  local version
  version=$(remote "$REMOTE_DIR/current/bootstrap.sh --version") || die "Gaia is not usable in $REMOTE_DIR/current on $HOST"
  [[ -n $LOCAL ]] && info "gaia ready: $version in $REMOTE_DIR/current"
  return 0
}

# Follows the detached run until it ends, then copies the report. Exit code = Gaia's exit code.
cmd_attach() {
  local sudo rc
  sudo=$(remote_sudo_prefix)
  remote "${sudo}bash -s" <<EOF ||
tail -n +1 -F $REMOTE_OUT 2>/dev/null &
t=\$!
until [ -f $REMOTE_RC ] || ! pgrep -f '[a]gent-run.sh' >/dev/null; do sleep 3; done
sleep 1
kill \$t 2>/dev/null
wait \$t 2>/dev/null
exit 0
EOF
    die "lost the connection while following the run; it continues on the server. Resume with: $0 attach $TARGET -p $PORT"
  rc=$(remote "${sudo}cat $REMOTE_RC" 2>/dev/null) ||
    die "the run ended without an exit code (interrupted, e.g. by a reboot); see $REMOTE_OUT on the server"
  if remote "${sudo}cat $REMOTE_REPORT" >"$REPORT.tmp" 2>/dev/null && [[ -s $REPORT.tmp ]]; then
    mv -f "$REPORT.tmp" "$REPORT"
    chmod 600 "$REPORT" 2>/dev/null || true
    info "report copied to $REPORT"
  else
    rm -f "$REPORT.tmp"
    info "no report was produced (Gaia stopped before running steps; see the output above)"
  fi
  info "Gaia finished with exit code $rc"
  return "$rc"
}

cmd_run() {
  local sudo args="" a
  sudo=$(remote_sudo_prefix)
  for a in "${REST[@]}"; do
    case $a in --report-json | --report-json=*) die "do not pass --report-json; this tool sets it" ;; esac
    args+=" $(printf '%q' "$a")"
  done
  remote "${sudo}test -x $REMOTE_DIR/current/bootstrap.sh" || die "Gaia is not on the server yet; run: $0 fetch $TARGET -p $PORT"
  if remote "pgrep -f '[a]gent-run.sh' >/dev/null"; then
    die "a Gaia run started by this tool is still running; follow it with: $0 attach $TARGET -p $PORT"
  fi
  info "starting Gaia on $HOST:$args"
  # The command goes into a script file on the server (the arguments are already shell-quoted with
  # %q), then runs detached from the SSH session (setsid + nohup): a dropped connection does not
  # stop the run.
  remote "${sudo}bash -s" <<EOF
set -e
mkdir -p /var/lib/gaia /var/log/gaia
rm -f $REMOTE_RC $REMOTE_REPORT
cat >/var/lib/gaia/agent-run.sh <<'GAIA_JOB'
#!/usr/bin/env bash
$REMOTE_DIR/current/bootstrap.sh --yes --report-json $REMOTE_REPORT$args >$REMOTE_OUT 2>&1
echo \$? >$REMOTE_RC
GAIA_JOB
chmod 700 /var/lib/gaia/agent-run.sh
nohup setsid bash /var/lib/gaia/agent-run.sh >/dev/null 2>&1 </dev/null &
EOF
  cmd_attach
}

# A NEW connection (no master) as the administrator, plus the checks that prove nobody is locked out
# and that the old way in is closed.
cmd_verify() {
  local fresh=("${SSH_BASE[@]}" -o ControlMaster=no -o ControlPath=none) out fails=0
  check() { printf '  %-44s %s\n' "$1" "$2"; [[ $2 == PASS* ]] || fails=$((fails + 1)); }
  info "verifying with NEW connections to $HOST:$PORT"
  # shellcheck disable=SC2016 # expanded by the remote shell, on purpose.
  if out=$("${fresh[@]}" "$TARGET" 'echo "$(id -un) $(sudo -n true 2>/dev/null && echo sudo-ok || echo sudo-no)"' 2>&1); then
    check "login as $USER_ with your key" "PASS"
    if [[ $out == *sudo-ok* ]]; then
      check "sudo without a password" "PASS"
    else
      check "sudo without a password" "FAIL ($out)"
    fi
  else
    check "login as $USER_ with your key" "FAIL (${out##*$'\n'})"
  fi
  if [[ $OLD_USER != "$USER_" ]]; then
    if out=$("${fresh[@]}" "$OLD_USER@$HOST" true 2>&1); then
      check "login as $OLD_USER refused" "FAIL (still accepted)"
    else
      check "login as $OLD_USER refused" "PASS (${out##*: })"
    fi
  fi
  out=$("${fresh[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive "$TARGET" true 2>&1) || true
  if [[ $out == *"Permission denied (publickey)"* ]]; then
    check "password logins refused" "PASS (server offers publickey only)"
  else
    check "password logins refused" "FAIL (${out##*$'\n'})"
  fi
  ((fails == 0)) || die "$fails check(s) failed: keep the master connection open and fix it before closing anything"
  info "all checks passed"
}

case $CMD in
  open) cmd_open ;;
  close) cmd_close ;;
  check) cmd_check ;;
  fetch) cmd_fetch ;;
  run) cmd_run ;;
  attach) cmd_attach ;;
  verify) cmd_verify ;;
  *) usage ;;
esac
