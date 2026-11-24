# Custom steps

[Português](../pt-BR/custom-steps.md) | **English**

Custom steps let you add what is specific to your environment (Docker networks, application users,
backup cron jobs, monitoring agents) without modifying Gaia, with the same log, dry-run and status
as the base steps.

## Where they live

Every **executable** `*.sh` file in `steps.d/` (next to `bootstrap.sh`) or in
`GAIA_EXTRA_STEPS_DIR`. They run in lexical order, **after the modules** and before `audit-after`
and `summary`. The step name is `custom:` + the file name without the numeric prefix and `.sh`:
`steps.d/10-app-network.sh` becomes `custom:app-network`.

```bash
sudo ./bootstrap.sh --list-steps
sudo ./bootstrap.sh --only custom:app-network
sudo ./bootstrap.sh --skip custom:app-network
```

A file without the executable bit is skipped with a warning.

## Template

```bash
#!/usr/bin/env bash
# gaia-description: "app" docker network and the application's data directory
# shellcheck source=/dev/null
source "$GAIA_LIB_DIR/common.sh"
gaia_step_mode

if docker network inspect app >/dev/null 2>&1; then
  gaia_info "docker network already exists" "network=app"
else
  gaia_run docker network create app
fi

gaia_ensure_dir /srv/app/data 0750 "$GAIA_ADMIN_USER:$GAIA_ADMIN_USER"
```

- `# gaia-description:` shows up in `--list-steps` and in the log.
- `gaia_step_mode` turns on `set -Eeuo pipefail` and the error trap: a failing command ends the step
  with its file and line in the log.
- The whole configuration arrives as exported `GAIA_*` variables (`GAIA_ADMIN_USER`,
  `GAIA_SSH_PORT`, `GAIA_DRY_RUN`, `GAIA_MODULES`...). Your own variables can go in `gaia.conf` too,
  as long as they start with `GAIA_`.

## Helpers

| Helper | What it does |
|--------|--------------|
| `gaia_info`, `gaia_warn`, `gaia_error`, `gaia_debug` `"message" key=value...` | logs in Gaia's format, with secrets masked |
| `gaia_run command args...` | runs a command that **changes** the system; in dry-run it only says what it would do; marks the step as changed |
| `gaia_ensure_file path mode content [sensitive] [validator]` | ensures a file's content and mode, showing the diff |
| `gaia_ensure_checked_file path mode content description command...` | same, but runs `command` after the swap and restores the previous file if it fails |
| `gaia_ensure_dir path mode [owner:group]` | ensures a directory |
| `gaia_ensure_owner path owner:group` | ensures the owner |
| `gaia_ufw_ensure rule...` | adds a `ufw` rule if it does not exist yet (e.g. `allow 8443/tcp`) |
| `gaia_apt_install package...` | installs missing packages |
| `gaia_package_installed package` | tests whether a package is installed |
| `gaia_is_dry_run` | true under `--dry-run` |
| `gaia_skip "reason"` | ends the step with the `skipped` status |
| `gaia_fail "message"` | ends the step with the `failed` status |
| `gaia_path /etc/x` | real path taking `GAIA_ROOT` into account (tests) |

## Rules

1. **Nothing that changes the system outside the helpers.** Read-only commands
   (`docker network inspect`, `getent`, `grep`) may run directly; the ones that change something go
   through `gaia_run` or `gaia_ensure_*`. That is what keeps `--dry-run` trustworthy.
2. **Idempotency:** check before acting. On the second run the status must be `ok`.
3. **No secrets in the code.** Read them from mode-600 files outside the repository.

## Status

| Situation | Status |
|-----------|--------|
| some `gaia_run`/`gaia_ensure_*` changed something | `done` (`would change` in dry-run) |
| nothing needed to change | `ok` |
| `gaia_skip` | `skipped` |
| non-zero exit | `failed` (the following steps are skipped) |
