---
name: gaia
description: Harden a fresh Ubuntu or Debian server (VPS, VM, bare metal) over SSH with Gaia Harden — admin account with SSH keys, locked-down SSH, ufw firewall, fail2ban, security updates, kernel hardening, optional Docker/Caddy already secured — with a dry-run preview, a lock-out-safe run and a verification in a new session. Use when the user types /gaia user@host or asks to harden, secure or bootstrap a Linux server.
---

# /gaia — harden a server with Gaia Harden

Usage: `/gaia user@host [-p PORT] [--modules docker,caddy] [other bootstrap.sh options]`

You drive [Gaia Harden](https://github.com/Black-Ghost-Corp/gaia-harden) on a remote server through
`scripts/gaia-remote.sh` (next to this file). Gaia does the hardening; your job is to ask the few
questions that matter, show the preview, run it safely, prove the user can still log in, and report.

## Safety rules (never break these)

1. **Never ask for, read, print or handle passwords or private keys.** SSH uses the user's own
   ssh-agent / `~/.ssh` (the helper runs ssh in BatchMode). Only PUBLIC keys may be passed to Gaia.
   If a step needs a password (e.g. sudo asks for one), stop and tell the user what to do themselves.
2. **Preview before changing anything.** Always run the dry-run first, summarize it, and get an
   explicit "yes" from the user before the real run.
3. **Never leave the user locked out.** Keep the master connection open (`open`) for the whole run,
   and do not `close` it until `verify` passes with a NEW session. If verify fails, keep it open and
   fix through it (see "If verify fails").
4. **Do not reboot** unless the user asks, and only after `verify` passed.
5. **Report honestly**: read the JSON report; never report a step as successful unless its status is `done`/`ok`.
6. Run commands from this skill's folder or call the helper by its full path.

## Flow

### 1. Gather what is missing (ask only what you cannot infer, in one message)

- **Target**: `user@host` and port (default 22) from the arguments.
- **Administrator account** (`--admin-user`): suggest a name (e.g. `ops`, or the current login if it
  is not root). Root logins will be turned off; this account becomes the way in.
- **Administrator public keys**, one of:
  - nothing to do when the user logs in as root with a key: Gaia copies root's keys to the new
    account automatically (the most common VPS case);
  - `--github-keys <github-user>`;
  - `--ssh-key "<PUBLIC key line>"` (ask them to paste the `.pub` content, never the private file).
- **Modules** (`--modules`): `none`, `docker`, `caddy` or `docker,caddy`. Explain in one line each
  (Docker with ports filtered by the firewall; Caddy reverse proxy with automatic HTTPS).
- **Ports to open** (`--allow 80/tcp,443/tcp` for a website). For Docker containers that must be
  public, `GAIA_DOCKER_PUBLISH` (container ports) — use a config file only if needed.
- Optional: `--hostname`, `--timezone`, `--swap 2G` for small VPS, `--ssh-port`.

### 2. Connect and inspect

```bash
scripts/gaia-remote.sh open  user@host -p PORT
scripts/gaia-remote.sh check user@host -p PORT
```

`check` shows the system, privileges (root or passwordless sudo), keys present and what is
listening. Stop if the system is not Ubuntu 22.04/24.04/26.04 or Debian 12/13, or if neither root nor
passwordless sudo is available. If `open` warns that a master connection is not supported (Windows
OpenSSH), ask the user to open and keep their own SSH session to the server before continuing.

### 3. Put Gaia on the server

```bash
scripts/gaia-remote.sh fetch user@host -p PORT
```

Uses the latest **signed release** (verified by its installer) when one exists, otherwise a shallow
`git clone`. `--ref vX.Y.Z` pins a version.

### 4. Dry-run and confirmation

```bash
scripts/gaia-remote.sh run user@host -p PORT --report ./gaia-dry-run-HOST.json -- --dry-run <options>
```

Summarize from the JSON report (`jq` if available, otherwise read it):
- steps with `"status": "would change"` (what will change) and any `failed`;
- `ports.before` entries with `"exposed": true` (what is exposed today);
- `warnings`.
Then state the impact plainly — root and password logins will be refused, only `<admin>` with its
key will get in, the firewall will deny everything except SSH and the allowed ports — and ask for a
clear yes.

### 5. Real run

```bash
scripts/gaia-remote.sh run user@host -p PORT --report ./gaia-report-HOST.json -- <same options>
```

It usually takes 10 to 30 minutes (updates, two Lynis audits, modules), more on small or slow
machines. If your shell tool has a time limit, start this command in the background (e.g. Claude
Code's `run_in_background`) and wait for it to finish. The run is detached on the server, so a
timeout or a dropped connection does not stop it: resume with
`scripts/gaia-remote.sh attach user@host -p PORT --report ./gaia-report-HOST.json`.
Exit code 0 = success; 1 = a step failed (read `errors` in the report).

### 6. Verify with a NEW session (mandatory)

```bash
scripts/gaia-remote.sh verify ADMIN@host -p PORT --old-user <the user you connected as>
```

It opens fresh connections (not the master) and checks: the admin logs in with the key, `sudo`
works, the old login user (e.g. root) is refused, password logins are refused. With `--ssh-port`
changed, verify on the NEW port.

### 7. Report and close

From `gaia-report-HOST.json`, tell the user:
- `result`, and every step that is not `done`/`ok`/`not selected`/`skipped`;
- `ports.after` with exposure, `ports.exposed_after` (should be 0) and `ports.closed`;
- `lynis.before -> lynis.after (+gain)`;
- `reboot_required` (offer to reboot only now that verify passed) and `warnings`;
- `next_steps`;
- always: **open the same ports in the cloud provider's firewall** (security group / cloud
  firewall) — e.g. 80/443 for a website — or the site will not be reachable even though ufw allows it;
- where the full log is on the server (`log_file`).

Finally `scripts/gaia-remote.sh close user@host -p PORT`.

## If verify fails

Do not close the master connection. Through it (`ssh -o ControlPath=~/.ssh/gaia-%r@%h-%p user@host`):
- show the tail of `/var/log/gaia/agent-run.out` and the report's `errors`;
- if the admin cannot log in, check `/home/<admin>/.ssh/authorized_keys` and fix the key;
- as a last resort, remove `/etc/ssh/sshd_config.d/00-gaia.conf` and `systemctl reload ssh`
  (restores the previous SSH behavior), then explain what happened.
Never tell the user it is safe to close their session until `verify` passes.

## Reference

- Options: `bootstrap.sh --help`; steps and modules: `docs/en/steps.md`, `docs/en/modules.md`.
- JSON report format: `docs/en/report.md` (schema `gaia-report/1`).
