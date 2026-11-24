# shellcheck shell=bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# gaia-description: directories with owner and mode (GAIA_DIRS), e.g. for applications and backups

# GAIA_DIRS: "path:owner:group:mode" entries separated by spaces; @admin = GAIA_ADMIN_USER.
step_run() {
  [[ -n $GAIA_DIRS ]] || gaia_skip "GAIA_DIRS not set (no directories to manage)"
  local entry path owner group mode
  for entry in $GAIA_DIRS; do
    [[ $entry =~ ^(/[^:]+):([^:]+):([^:]+):([0-7]{3,4})$ ]] ||
      gaia_fail "invalid entry in GAIA_DIRS: '$entry' (format: /path:owner:group:mode, e.g. /srv/apps:@admin:@admin:0755)"
    path=${BASH_REMATCH[1]}
    owner=${BASH_REMATCH[2]}
    group=${BASH_REMATCH[3]}
    mode=${BASH_REMATCH[4]}
    if [[ $owner == @admin || $group == @admin ]]; then
      [[ -n $GAIA_ADMIN_USER ]] || gaia_fail "GAIA_DIRS uses @admin, but GAIA_ADMIN_USER is empty"
      [[ $owner == @admin ]] && owner=$GAIA_ADMIN_USER
      [[ $group == @admin ]] && group=$(id -gn "$GAIA_ADMIN_USER" 2>/dev/null || echo "$GAIA_ADMIN_USER")
    fi
    gaia_ensure_dir "$path" "$mode" "$owner:$group"
    if ((GAIA_CHANGED)); then
      gaia_info "directory adjusted" "dir=$path" "owner=$owner:$group" "mode=$mode"
    else
      gaia_info "directory already correct" "dir=$path" "owner=$owner:$group" "mode=$mode"
    fi
  done
}
