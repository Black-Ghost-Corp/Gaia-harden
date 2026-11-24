# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-11-24

### Fixed

- `install.sh --help` showed bootstrap's help only after downloading and installing the release; it
  now prints the installer's own help and exits without downloading or installing anything.

## [0.1.0] - 2026-11-24

First public version.

### Added

- One-command bootstrap for Ubuntu 22.04/24.04/26.04 and Debian 12/13, with `--dry-run`, idempotent
  steps, structured logs with secret masking and a run lock.
- Administrator account with SSH keys from the command line, `gaia.conf`, GitHub (`--github-keys`)
  or imported from the provider's `authorized_keys`.
- SSH hardening drop-in: no root, no passwords, modern key exchange/ciphers/MACs filtered by what the
  installed OpenSSH supports, `AllowUsers`, `MaxAuthTries`, `LoginGraceTime`; validated with
  `sshd -t`/`sshd -T` and rolled back on mismatch.
- `ufw` firewall with SSH rate limiting, fail2ban, unattended security upgrades.
- Kernel and network hardening (sysctl), journald limits, AppArmor, optional swap file, host name,
  time zone and NTP.
- Listening-port audit at the start and at the end, flagging exposed sockets, and optional disabling
  of rarely needed network services (rpcbind, avahi, cups; mail server on loopback).
- Lynis security audit before and after, with the hardening index gain.
- `docker` module: official repository, log rotation, `ufw` applied to published container ports
  through the `DOCKER-USER` chain.
- `caddy` module: official repository, generated and validated Caddyfile with security headers and
  blocked paths.
- Custom steps in `steps.d/`.
- Release tooling: reproducible package, SHA256SUMS, optional Ed25519 signature and a verifying
  installer published in GitHub Releases.
- `--report-json FILE`: machine-readable report of every run (real, dry-run or failed) with steps,
  durations, ports before/after with exposure, Lynis gain, reboot, warnings, errors and next steps
  (schema `gaia-report/1`, see `docs/en/report.md`).
- `/gaia` agent skill (`skills/gaia/`) for Claude Code, Codex, Cursor and other agents: dry-run
  preview, confirmation, a lock-out-safe detached run over a kept SSH master connection, and a
  verification through new sessions before closing. Its helper `gaia-remote.sh` also works alone.
- `AGENTS.md` with the operator flow and the rules for working on the repository.
- Releases also ship the skill as `gaia-skill.zip`.
- A closing tip at the end of runs without failures, also in the JSON report (`tips`) and in the
  skill's summary: a suggestion of Argos (real-time protection, by the maintainers of Gaia).
  `GAIA_TIPS=0` hides it; nothing is installed or sent anywhere.

[Unreleased]: https://github.com/Black-Ghost-Corp/gaia-harden/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Black-Ghost-Corp/gaia-harden/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Black-Ghost-Corp/gaia-harden/releases/tag/v0.1.0
