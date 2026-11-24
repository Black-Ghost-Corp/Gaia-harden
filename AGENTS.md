# AGENTS.md

Instructions for AI coding agents (Codex, Cursor, Claude Code, Gemini CLI, Aider and others).
Humans: see [README.en.md](README.en.md) and [CONTRIBUTING.en.md](CONTRIBUTING.en.md).

## Hardening a server for the user

When the user asks you to harden, secure or bootstrap a Linux server with Gaia, follow
[`skills/gaia/SKILL.md`](skills/gaia/SKILL.md) exactly. It works in any agent that can run shell
commands; the helper is [`skills/gaia/scripts/gaia-remote.sh`](skills/gaia/scripts/gaia-remote.sh).
Short version:

1. Ask only what is missing: `user@host` and port, administrator name, public key source (keys
   already on root, `--github-keys USER` or a pasted PUBLIC key), modules (`docker`, `caddy`), ports
   to open.
2. `gaia-remote.sh open` (master connection kept open) → `check` → `fetch`.
3. `gaia-remote.sh run ... -- --dry-run <options>`; summarize the JSON report and get an explicit yes.
4. `gaia-remote.sh run ... -- <options>` (real run, detached on the server).
5. `gaia-remote.sh verify ADMIN@host --old-user <login user>` with NEW connections — mandatory.
6. Report from the JSON (`docs/en/report.md`): result, exposed ports, Lynis gain, reboot, warnings,
   next steps, and remind the user to open the same ports in the cloud provider's firewall.
7. `gaia-remote.sh close` only after verify passed.

Hard rules: never ask for or handle passwords or private keys; never skip the dry-run or the
verification; never reboot without the user's OK.

## Working on this repository

- Pure Bash 5 (`bootstrap.sh`, `lib/`), targeting Ubuntu 22.04/24.04/26.04 and Debian 12/13.
- Code, comments and log messages in **English**; user documentation exists in `docs/pt-BR` and
  `docs/en` and in both READMEs — update both languages.
- Every change to the system goes through the helpers in `lib/common.sh` (`gaia_run`,
  `gaia_ensure_file`, `gaia_ensure_dir`, `gaia_ufw_ensure`...), so `--dry-run`, logging and step
  status keep working. Never write to `/etc` or run changing commands directly.
- Steps must be idempotent: a second run changes nothing (status `ok`).
- New settings: `GAIA_*` default in `lib/config.sh`, validation in `gaia_config_validate`,
  documented in `gaia.conf.example` (a test checks they match).
- Every file starts with `# Copyright <year> Black Ghost Corporation` and
  `# SPDX-License-Identifier: Apache-2.0`.

### Tests

```bash
scripts/test.sh                     # bats (fake system, no changes to the machine) + shellcheck
scripts/test.sh integration         # real runs in throwaway Ubuntu/Debian containers (Docker)
```

Unit tests run the whole `bootstrap.sh` against a fake root (`GAIA_ROOT`) with system commands
replaced by simulators (`tests/fakes/fake-system.bash`). A new system command needs a simulator
there and an entry in `FAKE_COMMANDS` (`tests/test_helper.bash`). Cover: fresh machine, second run
without changes, `--dry-run` without mutations, error cases.
