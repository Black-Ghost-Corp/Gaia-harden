# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/Black-Ghost-Corp/Gaia-Bootstrapper/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Black-Ghost-Corp/Gaia-Bootstrapper/releases/tag/v0.1.0
