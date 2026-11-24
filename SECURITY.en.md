# Security policy

[Português](SECURITY.md) | **English**

Gaia configures the security of servers; a flaw in it can leave many machines exposed. We take
reports seriously and thank everyone who reports responsibly.

## Supported versions

| Version | Supported |
|---------|-----------|
| latest `0.x` release | :white_check_mark: |
| older | :x: |

## How to report

**Do not open public issues, discussions or PRs for vulnerabilities.**

Use [GitHub private vulnerability reporting](https://github.com/Black-Ghost-Corp/gaia-harden/security/advisories/new)
and include, if possible:

- the version (`./bootstrap.sh --version`) and the system (`/etc/os-release`);
- what happens and its impact (e.g. exposed port, configuration that allows password login);
- steps to reproduce and the relevant log output (`/var/log/gaia/`), **without secrets**.

## What to expect

- Acknowledgement within **3 business days**.
- Initial assessment and fix plan within **10 business days**.
- Fix published in a release, with a security advisory (GHSA) and credit to the reporter, if wanted.

## Scope

In scope: the code in this repository (`bootstrap.sh`, `lib/`, `install.sh`, `scripts/`) and the
configuration it generates. Out of scope: vulnerabilities in third-party packages Gaia installs
(OpenSSH, Docker, Caddy, etc.) — report them to those projects.
