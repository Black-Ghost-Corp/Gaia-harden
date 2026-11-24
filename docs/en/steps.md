# Steps

[Português](../pt-BR/steps.md) | **English**

Gaia runs the steps in the order below. `./bootstrap.sh --list-steps` shows the real list (including
modules and custom steps). Use `--only` and `--skip` to choose which ones run; unknown names are
rejected.

Full order: base steps numbered below 90 → selected modules → custom steps (`steps.d/`) → base steps
numbered 90 and up (`audit-after`, `summary`).

Every step ends with a status: `done`, `ok`, `skipped`, `failed`, `would change` (dry-run) or
`not selected` (module not chosen). If a step fails, the following ones are skipped and the run
exits non-zero.

## preflight

Changes nothing. Checks: running as root, Bash 5, supported system (Ubuntu 22.04/24.04/26.04,
Debian 12/13), systemd as init (`GAIA_REQUIRE_SYSTEMD`), free space on `/` (`GAIA_MIN_DISK_GB`) and
HTTPS access to the apt mirrors and — only when they are used — to the Docker and Caddy repositories
and GitHub (`GAIA_CHECK_INTERNET`). Warns when running inside a container. Records the listening
sockets (`ss -tulpn`) to compare at the end.

## audit-before

Installs [Lynis](https://cisofy.com/lynis/) and runs `lynis audit system`, keeping the hardening
index and the report in `/var/lib/gaia/audit` (mode 700). Turn it off with `--no-audit` or
`GAIA_AUDIT=0`. A Lynis failure is a warning, not a failed run.

## packages

`apt-get update` (at most once every `GAIA_APT_UPDATE_MAX_AGE` seconds), `full-upgrade` when updates
are available (`GAIA_APT_FULL_UPGRADE`) and the base packages, with no prompts and no recommends:
`ca-certificates curl gnupg jq iproute2 ufw fail2ban python3-systemd unattended-upgrades sudo
openssh-server tzdata`, the NTP client (`chrony` or `systemd-timesyncd`), `apparmor` and
`GAIA_EXTRA_PACKAGES`.

## time

Time zone (`GAIA_TIMEZONE`, default `UTC`) through `timedatectl` and NTP synchronization: `chrony`
on Debian and Ubuntu 26.04, `systemd-timesyncd` elsewhere (`GAIA_NTP_PACKAGE` overrides it).

## hostname

Runs only when `GAIA_HOSTNAME` (or `--hostname`) is set. Applies it with `hostnamectl`, updates the
`127.0.1.1` line in `/etc/hosts` (full and short name) and writes
`/etc/cloud/cloud.cfg.d/99-gaia-hostname.cfg` with `preserve_hostname: true` so that cloud-init does
not change the name on the next boot.

## admin-user

Creates (or adjusts) the `GAIA_ADMIN_USER` account with the `GAIA_ADMIN_SHELL` shell, in the `sudo`
group, and installs the public keys in `~/.ssh/authorized_keys` (700/600). Key sources:

1. `GAIA_ADMIN_SSH_KEYS` / `--ssh-key`;
2. `GAIA_ADMIN_GITHUB_KEYS` / `--github-keys` (`https://github.com/<user>.keys`);
3. with `GAIA_ADMIN_IMPORT_KEYS=auto` and none of the above: the keys in `/root/.ssh/authorized_keys`
   and in the sudo user's file (options such as the `command="echo Please login as..."` prefix of
   cloud images are removed).

Without any valid key the step fails — Gaia never turns off password login leaving you without
access. With `GAIA_ADMIN_SUDO_NOPASSWD=1` it writes `/etc/sudoers.d/90-gaia-<user>`, validated with
`visudo -c`.

## ssh

Writes the `GAIA_SSH_DROPIN` drop-in (default `/etc/ssh/sshd_config.d/00-gaia.conf`, read before
the others) with:

```text
Port 22                          # GAIA_SSH_PORT
PermitRootLogin no               # GAIA_SSH_PERMIT_ROOT_LOGIN
PasswordAuthentication no        # GAIA_SSH_PASSWORD_AUTH
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes
PermitUserEnvironment no
MaxAuthTries 3                   # GAIA_SSH_MAX_AUTH_TRIES
LoginGraceTime 30                # GAIA_SSH_LOGIN_GRACE_TIME
ClientAliveInterval 300          # GAIA_SSH_CLIENT_ALIVE_INTERVAL
ClientAliveCountMax 2
AllowTcpForwarding local         # GAIA_SSH_TCP_FORWARDING
AllowAgentForwarding no          # GAIA_SSH_AGENT_FORWARDING
X11Forwarding no
LogLevel VERBOSE
AllowUsers <admin>               # GAIA_SSH_ALLOW_USERS
KexAlgorithms / Ciphers / MACs   # GAIA_SSH_MODERN_CRYPTO
```

With `GAIA_SSH_MODERN_CRYPTO=1` only modern algorithms remain — hybrid post-quantum key exchange
(`mlkem768x25519-sha256`, `sntrup761x25519-sha512`) and `curve25519`, AEAD/CTR ciphers and
encrypt-then-MAC MACs — filtered by what the installed OpenSSH supports (`ssh -Q`).

Lock-out protections:

- the file is validated with `sshd -t` before it takes effect;
- then `sshd -T` checks that the **effective** values are the expected ones (another file in
  `sshd_config.d` could override them); if not, the previous drop-in is restored;
- `AllowUsers` warns when it leaves out users that have `authorized_keys`;
- when the port changes, the new one is allowed in `ufw` (with `limit`) **before** the reload; on
  Ubuntu 24.04+ `ssh.socket` is restarted to listen on the new port;
- the service gets a `reload`, never a `restart`: your current session stays up.

## firewall

`ufw` denying inbound and allowing outbound by default, SSH allowed with `limit` (blocks more than 6
connections in 30 s from the same IP; `GAIA_SSH_RATE_LIMIT=0` uses `allow`), then the
`GAIA_FIREWALL_ALLOW` / `--allow` rules (`port/proto`, `start:end/proto`), and only then
`ufw enable`. When the SSH port changes, the old rule stays and a warning asks you to remove it after
testing the new one.

## fail2ban

`/etc/fail2ban/jail.d/gaia.local` with the `sshd` jail on the configured port (`GAIA_FAIL2BAN_*`:
bantime, findtime, maxretry, backend, ignoreip), validated with `fail2ban-client -t` (with rollback)
and applied with `reload`.

## auto-updates

`unattended-upgrades` with the distribution's **security** origin only (the default origins are
cleared with `#clear`), and automatic reboot off (`GAIA_AUTO_REBOOT=1` and
`GAIA_AUTO_REBOOT_TIME` turn it on).

## sysctl

`/etc/sysctl.d/90-gaia-hardening.conf`, applied with `sysctl -e -q -p` (keys the kernel does not
know are ignored):

- network: `rp_filter` (anti-spoofing), no `accept_redirects`/`secure_redirects`/`send_redirects`,
  no source routing, `log_martians`, ignore ICMP broadcasts and bogus ICMP errors, `tcp_syncookies`,
  `tcp_rfc1337`;
- kernel: `kptr_restrict=2`, `dmesg_restrict=1`, `yama.ptrace_scope=1`,
  `unprivileged_bpf_disabled=1`, `bpf_jit_harden=2`, `randomize_va_space=2`, `sysrq=0`;
- file system: `protected_hardlinks/symlinks`, `protected_fifos/regular=2`, `suid_dumpable=0`.

IP forwarding is **not** changed (Docker needs it). `GAIA_SYSCTL_EXTRA` adds keys (`key=value`).
Skipped in containers; turn it off with `GAIA_SYSCTL=0`.

## journald

`/etc/systemd/journald.conf.d/90-gaia.conf`: persistent, compressed storage capped at
`GAIA_JOURNALD_MAX_USE` (default 500M). Restarts `systemd-journald` only when the file changes.

## apparmor

Ensures the `apparmor` service is active and reports how many profiles are loaded and in enforce
mode. If AppArmor is disabled in the kernel, it warns and skips. Skipped in containers;
`GAIA_APPARMOR=0` turns it off.

## swap

Only with `GAIA_SWAP_SIZE` / `--swap` (e.g. `2G`). Creates `GAIA_SWAP_FILE` (600), enables it, adds
it to `/etc/fstab` and sets `vm.swappiness` (`GAIA_SWAPPINESS`, default 10). A machine that already
has swap is left alone. Skipped in containers.

## services

- Turns off (`systemctl disable --now`) `rpcbind`, `avahi-daemon` and `cups`, only when they are
  enabled or running (`GAIA_DISABLE_UNUSED_SERVICES=0` keeps them). `GAIA_DISABLE_SERVICES` adds
  units.
- Local mail server (`GAIA_MTA_LOCAL_ONLY=1`): `postfix` with `inet_interfaces=loopback-only` and
  `exim4` with `dc_local_interfaces='127.0.0.1 ; ::1'`.

## directories

Creates the `GAIA_DIRS` directories (`path:owner:group:mode`, `@admin` = administrator account) and
fixes owner and mode when they drift.

## audit-after

Runs Lynis again and shows `Lynis hardening index: before -> after (+gain)`, keeping the history in
`/var/lib/gaia/audit/history`.

## summary

Lists the sockets listening now and the exposure of each one:

| Exposure | Meaning |
|----------|---------|
| `local only` | listens on loopback only |
| `public, allowed by firewall` | open on purpose (a `ufw` rule) |
| `blocked by firewall` | listens on all interfaces, but `ufw` blocks it |
| `docker, filtered by ufw route rules` | container port filtered by the `docker` module |
| `EXPOSED (Docker bypasses ufw)` | container port open to the internet despite `ufw` |
| `EXPOSED (firewall inactive)` | listens publicly with the firewall off |

It also shows what stopped listening since `preflight` and the next steps: test SSH from a **new**
session, check `sudo`, reboot if the system asks for it.
