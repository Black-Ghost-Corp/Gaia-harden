#!/usr/bin/env bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# Gaia — turns a freshly installed Linux server (Ubuntu 22.04/24.04/26.04, Debian 12/13) into a
# hardened host, and optionally installs modules (Docker, Caddy...) already secured.
#
# Usage: sudo ./bootstrap.sh [--modules docker,caddy] [--admin-user NAME] [--dry-run] [--yes] ...
#        ./bootstrap.sh --help
set -Eeuo pipefail

GAIA_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$GAIA_HOME/lib/common.sh"
# shellcheck source=lib/config.sh
source "$GAIA_HOME/lib/config.sh"
# shellcheck source=lib/os.sh
source "$GAIA_HOME/lib/os.sh"
# shellcheck source=lib/ports.sh
source "$GAIA_HOME/lib/ports.sh"
# shellcheck source=lib/report.sh
source "$GAIA_HOME/lib/report.sh"
# shellcheck source=lib/runner.sh
source "$GAIA_HOME/lib/runner.sh"

trap 'gaia__on_error "$?" "$LINENO" "${BASH_SOURCE[0]:-?}" "$BASH_COMMAND"' ERR

gaia_main "$@"
