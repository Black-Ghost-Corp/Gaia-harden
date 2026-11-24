## What and why

<!-- The problem this solves and the approach. Link the issue: "Closes #<number>". -->

## How it was tested

<!-- bats files added/changed, integration image(s), a real VM run if relevant. -->

## Checklist

- [ ] Changes to the system go through the helpers (`gaia_run`, `gaia_ensure_*`) and respect `--dry-run`
- [ ] A second run changes nothing (status `ok`), covered by a test
- [ ] `scripts/test.sh` passes (bats + shellcheck)
- [ ] New `GAIA_*` settings are validated in `lib/config.sh` and documented in `gaia.conf.example`
- [ ] Docs updated in both languages (`docs/pt-BR`, `docs/en`, READMEs) when behavior changes
- [ ] `CHANGELOG.md` updated under `Unreleased`
