#!/usr/bin/env bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# Runs Gaia's tests in containers (works on Linux, macOS and Git Bash on Windows).
#
#   scripts/test.sh                       unit tests (bats) + shellcheck
#   scripts/test.sh bats [file.bats...]   unit tests only
#   scripts/test.sh shellcheck            shellcheck only
#   scripts/test.sh integration [image...] real run inside throwaway containers
#                                         (default: ubuntu:22.04 ubuntu:24.04 ubuntu:26.04 debian:12 debian:13)
#
# Pinned versions so results are reproducible.
set -Eeuo pipefail

BATS_BASE_IMAGE="bats/bats:1.11.1"
BATS_IMAGE="gaia-tests:bats-1.11.1-1" # suffix changes when tests/Dockerfile changes
SHELLCHECK_IMAGE="koalaman/shellcheck:v0.10.0"
INTEGRATION_IMAGES=("ubuntu:22.04" "ubuntu:24.04" "ubuntu:26.04" "debian:12" "debian:13")

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Git Bash converts POSIX paths in docker arguments; this turns the conversion off.
export MSYS_NO_PATHCONV=1
# On Git Bash, docker needs the Windows path format (C:/...).
if command -v cygpath >/dev/null 2>&1; then VOLUME=$(cygpath -m "$ROOT"); else VOLUME=$ROOT; fi

bats_image() {
  if ! docker image inspect "$BATS_IMAGE" >/dev/null 2>&1; then
    echo "[test] building $BATS_IMAGE from $BATS_BASE_IMAGE"
    docker build -q -t "$BATS_IMAGE" "$VOLUME/tests" >/dev/null
  fi
}

run_bats() {
  bats_image
  local targets=("$@")
  ((${#targets[@]})) || targets=(/code/tests)
  docker run --rm -v "$VOLUME:/code:ro" -w /code -e BATS_LIB_PATH=/usr/lib/bats "$BATS_IMAGE" \
    --jobs "$(nproc 2>/dev/null || echo 2)" --no-parallelize-within-files --print-output-on-failure "${targets[@]}"
}

run_shellcheck() {
  local files
  mapfile -t files < <(cd "$ROOT" && {
    echo bootstrap.sh
    echo install.sh
    ls lib/*.sh lib/steps/*.sh lib/modules/*.sh scripts/*.sh tests/fakes/*.bash tests/integration/*.sh skills/*/scripts/*.sh 2>/dev/null
  })
  docker run --rm -v "$VOLUME:/code:ro" -w /code "$SHELLCHECK_IMAGE" -x -P SCRIPTDIR "${files[@]}"
  # Disabled on purpose in the tests:
  #   SC2016 strings with a literal $ are the expected content of generated files and scripts;
  #   SC2030/SC2031 each bats @test runs in a subshell, so exporting inside a test is intended;
  #   SC2034 variables from test_helper.bash are used by the .bats files.
  docker run --rm -v "$VOLUME:/code:ro" -w /code "$SHELLCHECK_IMAGE" -x -s bash -e SC2016,SC2030,SC2031,SC2034 \
    tests/*.bats tests/test_helper.bash
  echo "[test] shellcheck: no issues found"
}

run_integration() {
  local images=("$@") img
  ((${#images[@]})) || images=("${INTEGRATION_IMAGES[@]}")
  for img in "${images[@]}"; do
    echo "[test] integration on $img"
    docker run --rm --cap-add NET_ADMIN -v "$VOLUME:/gaia-src:ro" "$img" bash /gaia-src/tests/integration/run.sh
  done
}

case ${1:-all} in
  bats) shift; run_bats "$@" ;;
  shellcheck) run_shellcheck ;;
  integration) shift; run_integration "$@" ;;
  all) run_bats && run_shellcheck ;;
  *) echo "usage: $0 [bats|shellcheck|integration|all]" >&2; exit 2 ;;
esac
