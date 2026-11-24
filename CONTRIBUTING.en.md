# Contributing to Gaia

[Português](CONTRIBUTING.md) | **English**

Thanks for your interest! This guide explains how to propose changes in a way that makes review easy.

## Before you start

- For small fixes (typo, message, test), open the PR directly.
- For anything bigger (new module, new step, change of a default), first open an
  [issue](https://github.com/Black-Ghost-Corp/gaia-harden/issues) describing the problem and
  the proposal. Default changes affect every server that runs Gaia, so we discuss them first.
- Vulnerabilities do **not** go into public issues: see [SECURITY.en.md](SECURITY.en.md).
- By taking part, you agree to the [code of conduct](CODE_OF_CONDUCT.md).

## Environment

`scripts/test.sh` runs everything in containers with pinned versions, so Docker is all you need:

```bash
scripts/test.sh                              # bats + shellcheck
scripts/test.sh bats /code/tests/15-ssh.bats # a single file
scripts/test.sh integration ubuntu:24.04     # real run inside a throwaway container
```

Without Docker, install Bash 5, [bats-core](https://github.com/bats-core/bats-core) with
`bats-support` and `bats-assert`, [shellcheck](https://www.shellcheck.net/) 0.10+ and `jq`, then run
`BATS_LIB_PATH=<libraries dir> bats tests`.

## Code rules

1. **English** in code, comments, logs and error messages. Documentation has Portuguese and English
   versions: update both.
2. **Every change to the system goes through the helpers** (`gaia_run`, `gaia_ensure_file`,
   `gaia_ensure_dir`, `gaia_ufw_ensure`...). That is what guarantees `--dry-run`, the log and the
   step status. Never write directly to `/etc` or call commands that change the system outside them.
3. **Idempotency.** Run twice in a row: the second run must change nothing (status `ok`). Every test
   for a new step covers this.
4. **Validate before swapping.** Files that can break access or services (sshd, sudoers, ufw, proxy)
   use `gaia_ensure_checked_file` or a validator, with rollback.
5. **Secure by default, configurable.** New behavior that closes something is on by default; what
   may surprise users gets a `GAIA_*` variable documented in `gaia.conf.example` and validated in
   `lib/config.sh`.
6. **No new dependencies** on the server beyond the distribution's official packages.
7. A `# gaia-description:` header in every step and module (shown by `--list-steps` and in the log).
8. Every new file starts with the license header:
   `# Copyright <year> Black Ghost Corporation` and `# SPDX-License-Identifier: Apache-2.0`.

## Tests

- Unit tests live in `tests/NN-name.bats` and run Gaia against a fake root with simulated commands in
  `tests/fakes/fake-system.bash`. If your step calls a new system command, add a simulator there and
  its name to `FAKE_COMMANDS` (`tests/test_helper.bash`).
- Cover: fresh machine, second run with no changes, `--dry-run` with no mutations, and error cases.
- Changes to real package or service installation also deserve a check in
  `tests/integration/run.sh`.

## Pull requests

- One topic per PR, describing the problem, the solution and how it was tested.
- Commits in the [Conventional Commits](https://www.conventionalcommits.org/) format (`feat:`,
  `fix:`, `docs:`, `test:`...).
- CI (bats, shellcheck and integration) must pass.
- Update `CHANGELOG.md` under `Unreleased`.

By submitting a contribution, you agree to license it under the [Apache License 2.0](LICENSE).
