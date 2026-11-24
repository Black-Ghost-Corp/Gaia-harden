# Gaia Harden

[![CI](https://github.com/Black-Ghost-Corp/gaia-harden/actions/workflows/ci.yml/badge.svg)](https://github.com/Black-Ghost-Corp/gaia-harden/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Black-Ghost-Corp/gaia-harden?include_prereleases&sort=semver)](https://github.com/Black-Ghost-Corp/gaia-harden/releases)
![Platforms](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)
![Platforms](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)

[Português](README.md) | **English**

Gaia turns a freshly created Ubuntu or Debian server (VPS, bare metal or VM) into a hardened host
with **a single command**: an administrator account with SSH keys, locked-down SSH, a firewall that
closes everything that does not need to be open, fail2ban, automatic security updates, kernel and
network hardening, a security audit before and after — and, if you want, software such as Docker
and Caddy **installed already secured**.

It is plain Bash, with no agents or external dependencies, idempotent (running it again changes
nothing that is already right) and has `--dry-run` to show everything it would change first.

```bash
git clone https://github.com/Black-Ghost-Corp/gaia-harden.git
cd gaia-harden
sudo ./bootstrap.sh --dry-run   # shows what would change, changes nothing
sudo ./bootstrap.sh             # applies it
```

> [!IMPORTANT]
> Gaia turns off root and password logins over SSH. It only does so after making sure the
> administrator account has a valid public key, and the final summary asks you to test access from a
> **new** session before closing the current one. Read [Before you run it](#before-you-run-it).

## Contents

- [Why Gaia](#why-gaia)
- [What it does](#what-it-does)
- [Before you run it](#before-you-run-it)
- [Quick start](#quick-start)
- [Using with AI agents](#using-with-ai-agents)
- [Modules](#modules)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Custom steps](#custom-steps)
- [Compatibility](#compatibility)
- [Development and testing](#development-and-testing)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## Why Gaia

Every new server on the internet gets login attempts within minutes. The checklist to make it
reasonably safe is always the same and easy to get wrong by hand: a forgotten `AllowUsers`, a
firewall enabled before SSH was allowed, a Docker container publishing a port that `ufw` never sees.

Gaia encodes that checklist in a **verifiable** way:

- **Secure by default.** No root login, no SSH passwords, inbound traffic denied.
- **No lock-outs.** The SSH configuration is validated with `sshd -t` and checked with `sshd -T`
  before it takes effect; if anything does not match, it is rolled back. The firewall allows SSH
  before it is enabled.
- **Transparent.** Every action is a log line (`[gaia][level][step=x] message key=value`); secrets
  are masked; `--dry-run` shows exactly what would change.
- **Measurable.** [Lynis](https://cisofy.com/lynis/) runs before and after and shows the hardening
  index gain (e.g. `Lynis hardening index: 58 -> 81 (+23)`). Listening ports are audited at the start
  and at the end, pointing out what is exposed to the internet.
- **Idempotent.** Running it again only fixes what drifted.

## What it does

| # | Step | What it guarantees |
|---|------|--------------------|
| 1 | `preflight` | root, supported system, free disk, access to repositories, systemd; records what is listening (changes nothing) |
| 2 | `audit-before` | baseline Lynis audit (reference hardening index) |
| 3 | `packages` | `apt update`, `full-upgrade` (configurable) and base packages |
| 4 | `time` | time zone and NTP synchronization |
| 5 | `hostname` | host name in `hostnamectl`, `/etc/hosts`, preserved across cloud-init reboots |
| 6 | `admin-user` | administrator account in the `sudo` group, with SSH keys (literal, from GitHub or imported from the provider) |
| 7 | `ssh` | drop-in with root and passwords off, modern crypto, `AllowUsers`, `MaxAuthTries`, `LoginGraceTime`; validated with rollback |
| 8 | `firewall` | `ufw` denying inbound, SSH rate-limited (`limit`) and allowed before enabling, extra rules |
| 9 | `fail2ban` | `sshd` jail on the configured port |
| 10 | `auto-updates` | `unattended-upgrades` with security updates only; optional automatic reboot |
| 11 | `sysctl` | anti-spoofing, no redirects, SYN cookies, restricted kernel information |
| 12 | `journald` | persistent, compressed journal with a disk cap |
| 13 | `apparmor` | AppArmor enabled and loading profiles |
| 14 | `swap` | optional swap file for small VPS, with low swappiness |
| 15 | `services` | turns off network services a server rarely needs (rpcbind, avahi, cups) and keeps the local mail server on loopback |
| 16 | `directories` | directories with owner and mode (e.g. `/srv/apps`) |
| — | modules | optional software, already hardened (see [Modules](#modules)) |
| — | custom steps | your own scripts in `steps.d/` |
| 19 | `audit-after` | final Lynis audit, compared with the baseline |
| 20 | `summary` | what listens now, what was closed, and the next steps |

Step details: [docs/en/steps.md](docs/en/steps.md).

## Before you run it

1. **Have a public SSH key** for the administrator account. Gaia accepts any of these sources, in
   this order:
   - `--ssh-key "ssh-ed25519 AAAA... you@laptop"` (or `GAIA_ADMIN_SSH_KEYS` in `gaia.conf`);
   - `--github-keys your-user` (imports `https://github.com/your-user.keys`);
   - the keys your VPS provider already placed in `/root/.ssh/authorized_keys` (imported
     automatically when no other key was given).
2. **Keep your current session open** until you can log in with the new account from a second one.
3. **Open in your provider's firewall** (security group, cloud firewall) the same ports you allow in
   Gaia, such as 80/443 for a website.
4. Run with `--dry-run` first.

## Quick start

### From the repository (recommended)

```bash
git clone https://github.com/Black-Ghost-Corp/gaia-harden.git
cd gaia-harden

# Interactive: asks for the administrator account and the modules.
sudo ./bootstrap.sh

# Non-interactive: everything on the command line.
sudo ./bootstrap.sh --yes \
  --admin-user alice \
  --github-keys alice \
  --modules docker,caddy \
  --allow 80/tcp,443/tcp \
  --hostname web-01.example.com \
  --timezone Europe/Lisbon \
  --swap 2G
```

### With the release installer

The installer downloads the [latest release](https://github.com/Black-Ghost-Corp/gaia-harden/releases/latest)
and checks its SHA-256 and Ed25519 signature **before** running anything:

```bash
curl -fsSL https://github.com/Black-Ghost-Corp/gaia-harden/releases/latest/download/install.sh | sudo bash
# with options:
curl -fsSL https://github.com/Black-Ghost-Corp/gaia-harden/releases/latest/download/install.sh \
  | sudo bash -s -- --modules docker --admin-user alice --yes
```

The release lives in `/opt/gaia/releases/<version>` (linked from `/opt/gaia/current`), and an
`/opt/gaia/gaia.conf` is used automatically when present.

### Options

```text
--modules LIST       optional modules, comma separated (e.g. docker,caddy; "none" or "all")
--admin-user NAME    administrator account (default: the user who ran sudo)
--ssh-key KEY        administrator public key (repeatable)
--github-keys USER   import keys from https://github.com/USER.keys (repeatable)
--ssh-port PORT      SSH port (default 22)
--allow RULES        extra inbound firewall rules (e.g. 80/tcp,443/tcp)
--hostname NAME      host name
--timezone TZ        time zone (default UTC)
--swap SIZE          create a swap file (e.g. 2G)
--no-audit           skip the Lynis audit
--config FILE        configuration file (default: gaia.conf next to bootstrap.sh, if present)
--dry-run            show what each step would change, without changing anything
--report-json FILE   write a JSON report of the run (see docs/en/report.md)
--only LIST          run only these steps
--skip LIST          skip these steps
--list-steps         list the steps
--yes, -y            do not ask anything
```

## Using with AI agents

Gaia ships a `/gaia` skill for AI agents (Claude Code, Codex, Cursor and others). You say
`/gaia root@203.0.113.10` and the agent drives the whole thing safely:
- it asks only what it needs: administrator account, public key, modules and ports;
- it runs the **dry-run** and shows what will change;
- it applies only after your "yes", keeping the current connection open as a safety net;
- it **tests the login in a new session** before calling the job done;
- it ends with a summary of the [JSON report](docs/en/report.md): exposed ports, Lynis gain,
  pending reboot and next steps.

The agent never asks for passwords or private keys: SSH uses your own `ssh-agent`.

### One-prompt setup

Paste this into your agent:

```text
Install the "gaia" skill from Gaia Harden for me. Before copying anything, show me the plan and the
paths you will use.
1. Fetch the repository: git clone --depth 1 https://github.com/Black-Ghost-Corp/gaia-harden.git
   into a temporary folder.
2. Copy the skills/gaia folder (SKILL.md and scripts/) into your skills directory:
   - Claude Code: ~/.claude/skills/gaia/ (all projects). Ask me whether I prefer
     .claude/skills/gaia/ for the current project only.
   - Other agents: your equivalent location; if there is none, keep the folder and use the
     repository's AGENTS.md as the instructions.
3. Make scripts/gaia-remote.sh executable, list the copied files and show the first lines of
   SKILL.md.
4. Delete the temporary folder.
5. Explain how to use it: /gaia user@server [--modules docker,caddy].
Never ask me for passwords, tokens or private keys.
```

### Manual setup

```bash
git clone --depth 1 https://github.com/Black-Ghost-Corp/gaia-harden.git /tmp/gaia-harden
mkdir -p ~/.claude/skills
cp -r /tmp/gaia-harden/skills/gaia ~/.claude/skills/gaia
chmod +x ~/.claude/skills/gaia/scripts/gaia-remote.sh
rm -rf /tmp/gaia-harden
```

For other agents, copy `skills/gaia/` into their skills or instructions folder, or point the agent
to [AGENTS.md](AGENTS.md). `skills/gaia/scripts/gaia-remote.sh` also works on its own, without an
agent (`gaia-remote.sh --help`).

## Modules

Modules install software **already configured securely**. Choose them with `--modules`, with
`GAIA_MODULES` in `gaia.conf` or from the interactive menu.

| Module | What it installs | Hardening applied |
|--------|------------------|-------------------|
| `docker` | Docker Engine, compose and buildx from the official repository | GPG key checked by fingerprint; log rotation and `live-restore`; **ports published by containers now obey `ufw`** (`DOCKER-USER` chain), opened only through `GAIA_DOCKER_PUBLISH`; option to publish on `127.0.0.1` only; warning that the `docker` group is root-equivalent |
| `caddy` | Caddy (reverse proxy with automatic HTTPS) from the official repository | key checked; `Caddyfile` validated with `caddy validate` before replacing it; HSTS, `nosniff`, `Referrer-Policy`, no `Server` header; internal paths blocked with 403; reload without dropping connections |

> [!NOTE]
> By default Docker inserts its own iptables rules and **bypasses `ufw`**: a
> `docker run -p 5432:5432` is open to the internet even with the firewall "denying everything". The
> `docker` module fixes this, and the final port audit flags those cases as `EXPOSED`.

Details: [docs/en/modules.md](docs/en/modules.md).

## Configuration

Everything is optional. For repeated use (several identical machines), copy the example and adjust:

```bash
cp gaia.conf.example gaia.conf
chmod 600 gaia.conf
sudo ./bootstrap.sh            # picks up ./gaia.conf automatically
```

Precedence: **command line > `gaia.conf` > environment variables > defaults**. Invalid values are
rejected before any step runs. Every key is documented in [`gaia.conf.example`](gaia.conf.example)
and in [docs/en/configuration.md](docs/en/configuration.md).

## How it works

- **Idempotent steps.** Each step ends with a status: `done` (changed something), `ok` (already
  right), `skipped`, `failed`, `would change` (dry-run) or `not selected` (module not chosen).
- **Files validated before they take effect.** Critical configuration (sshd, sudoers, fail2ban, ufw
  rules, Caddyfile) is written to a temporary file, validated by the tool itself and only then swapped
  in; if validation fails, the previous file stays.
- **Third-party repositories verified.** GPG keys are downloaded over HTTPS and compared with the
  expected fingerprint before any `apt` call.
- **Logs.** Output on screen and in `/var/log/gaia/gaia-<date>.log` (mode 700), with secrets masked.
  A lock prevents two concurrent runs.

## Custom steps

Put executable scripts in `steps.d/` (or in `GAIA_EXTRA_STEPS_DIR`). They run after the modules,
receive the configuration and follow the same log, dry-run and status contract:

```bash
#!/usr/bin/env bash
# gaia-description: creates the application's docker network
source "$GAIA_LIB_DIR/common.sh"
gaia_step_mode

docker network inspect app >/dev/null 2>&1 || gaia_run docker network create app
```

Full guide: [docs/en/custom-steps.md](docs/en/custom-steps.md).

## Compatibility

| System | Versions | Architectures |
|--------|----------|---------------|
| Ubuntu Server | 22.04 LTS, 24.04 LTS, 26.04 LTS | amd64, arm64 |
| Debian | 12 (bookworm), 13 (trixie) | amd64, arm64 |

Requires Bash 5, systemd and root access. Inside containers the kernel, swap and AppArmor steps are
skipped (they belong to the host).

## Development and testing

```bash
scripts/test.sh               # bats (unit tests against a fake system) + shellcheck
scripts/test.sh integration   # real run inside throwaway Ubuntu/Debian containers
```

The unit tests run the whole of Gaia against a fake root (`GAIA_ROOT`) with system commands replaced
by simulators, without touching the machine. See [docs/en/testing.md](docs/en/testing.md) to test on
a VM.

## Roadmap

Next steps, in rough order of priority. Suggestions and PRs are welcome: open an
[issue](https://github.com/Black-Ghost-Corp/gaia-harden/issues) to discuss before starting
something big.

**Short term**

- [x] Signed releases (Ed25519) with a signature-verifying installer, published in GitHub Releases
- [x] Final report in JSON (`--report-json`); a Markdown version to attach to audits is next
- [x] `/gaia` skill for AI agents; next: an MCP server
- [ ] `auditd` with baseline rules and `AIDE` (file integrity)
- [ ] `--check` mode: only verifies compliance and exits non-zero on drift
- [ ] Ready-made profiles (`--profile web`, `--profile docker-host`, `--profile bastion`)

**New modules**

- [ ] Reverse proxies: hardened Nginx and Traefik
- [ ] Containers: Podman and rootless Docker; k3s with a CIS configuration
- [ ] Databases: PostgreSQL, MariaDB, Redis and MongoDB bound to loopback, with strong
      authentication and backups
- [ ] Private access: Tailscale and WireGuard (SSH over the VPN only)
- [ ] Active defense: CrowdSec as an alternative/complement to fail2ban
- [ ] Observability: node_exporter, Netdata and Uptime Kuma behind the proxy, no public ports
- [ ] Backups: restic or borg with scheduling and verification
- [ ] Runtimes: Node.js, Python and Go through version managers
- [ ] Isolated self-hosted CI runners
- [ ] Alerts (e-mail, Telegram, Slack) for logins, bans and pending updates

**Platforms**

- [ ] RHEL family (Rocky, AlmaLinux) with `firewalld` and SELinux
- [ ] Cloud images: ready-to-use cloud-init `user-data` for the main providers
- [ ] Own download mirror as an alternative to GitHub

## Contributing

Contributions are very welcome! Read the [contributing guide](CONTRIBUTING.en.md) and the
[code of conduct](CODE_OF_CONDUCT.md). In short: code and logs are in English, every change comes
with bats tests and passes `shellcheck`, and nothing that changes the system may bypass `--dry-run`.

## Security

Found a vulnerability? **Do not open a public issue.** Follow the
[security policy](SECURITY.en.md) and use
[GitHub private reporting](https://github.com/Black-Ghost-Corp/gaia-harden/security/advisories/new).

## License

Copyright © 2026 Black Ghost Corporation. Distributed under the [Apache License 2.0](LICENSE). See also the [NOTICE](NOTICE) file.

Gaia changes the security configuration of your server. It is provided "as is", without warranties;
review the `--dry-run` output and test on a throwaway machine before using it in production.
