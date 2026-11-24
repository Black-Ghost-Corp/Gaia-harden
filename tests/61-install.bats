#!/usr/bin/env bats
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# install.sh: downloads a GitHub release, verifies SHA-256 and signature, installs, runs bootstrap.
# GitHub is replaced by a curl shim that serves files from a local "releases" directory.

load test_helper

REL="$BATS_TEST_DIRNAME/../scripts/release.sh"

setup_extra() {
  VERSION=$(sed -n 's/^GAIA_VERSION="\(.*\)"$/\1/p' "$REPO/lib/runner.sh")
  TAG="v$VERSION"
  SERVED=$BATS_TEST_TMPDIR/served
  DEST=$BATS_TEST_TMPDIR/opt/gaia
  export SOURCE_DATE_EPOCH=1700000000 GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
  unset GAIA_RELEASE_PUBKEY GAIA_RELEASE_SIGNING_KEY GAIA_REPO
  mkdir -p "$SERVED"
  # curl shim: the latest-release redirect and the release downloads.
  cat >"$SHIMS/curl" <<EOF
#!/usr/bin/env bash
out="" url="" write=""
while ((\$#)); do
  case \$1 in
    -o) out=\$2; shift ;;
    -w) write=\$2; shift ;;
    --proto|--max-time|--retry|--tlsv1.2) [[ \$1 == --tlsv1.2 ]] || shift ;;
    -*) ;;
    *) url=\$1 ;;
  esac
  shift
done
echo "curl \$url" >>"$STUB_STATE/calls.log"
case \$url in
  https://github.com/*/releases/latest) printf 'https://github.com/x/y/releases/tag/%s' "\$(cat "$SERVED/latest")" ;;
  https://github.com/*/releases/download/*)
    f="$SERVED/\${url##*/}"
    [[ -f \$f ]] || exit 22
    cp "\$f" "\$out" ;;
  *) exit 6 ;;
esac
EOF
  chmod +x "$SHIMS/curl"
  echo "$TAG" >"$SERVED/latest"
}

publish() {
  bash "$REL" package "$TAG" "$SERVED" >/dev/null
  if [[ ${1:-} == signed ]]; then
    local d=$BATS_TEST_TMPDIR/keys
    mkdir -p "$d"
    openssl genpkey -algorithm ed25519 -outform DER -out "$d/k.der" 2>/dev/null
    PRIVATE=$(base64 -w0 "$d/k.der")
    PUBLIC=$(openssl pkey -inform DER -in "$d/k.der" -pubout -outform DER | tail -c 32 | xxd -p -c 64)
    GAIA_RELEASE_PUBKEY=$PUBLIC GAIA_RELEASE_SIGNING_KEY=$PRIVATE bash "$REL" sign "$SERVED" >/dev/null
  fi
}

install() { run bash "$REPO/install.sh" --dir "$DEST" "$@"; }

@test "latest release: downloads, checks SHA-256, installs and links current" {
  publish
  install --download-only
  assert_success
  assert_output --partial "downloading Gaia $TAG from GitHub"
  assert_output --partial 'only the SHA-256 sums were checked'
  [[ -f $DEST/releases/$VERSION/bootstrap.sh ]]
  [[ $(readlink "$DEST/current") == "$DEST/releases/$VERSION" ]]
  assert_called "releases/download/$TAG/gaia-$TAG.tar.gz$"
}

@test "--release picks a specific tag without asking for the latest" {
  publish
  install --download-only --release "$TAG"
  assert_success
  refute_called 'releases/latest$'
}

@test "a tampered package is refused and nothing is installed" {
  publish
  printf 'x' >>"$SERVED/gaia-$TAG.tar.gz"
  install --download-only
  assert_failure
  assert_output --partial 'does NOT match SHA256SUMS'
  [[ ! -e $DEST/current ]]
}

@test "signed release verified with the public key" {
  publish signed
  GAIA_RELEASE_PUBKEY=$PUBLIC install --download-only
  assert_success
  assert_output --partial 'package and signature verified'
}

@test "with a public key, an unsigned release is refused" {
  publish
  GAIA_RELEASE_PUBKEY=$(printf 'a%.0s' {1..64}) install --download-only
  assert_failure
  assert_output --partial 'is not signed; refusing'
}

@test "with the wrong public key, the release is refused" {
  publish signed
  GAIA_RELEASE_PUBKEY=$(printf 'b%.0s' {1..64}) install --download-only
  assert_failure
  assert_output --regexp 'does NOT match the release key|invalid release public key'
  [[ ! -e $DEST/current ]]
}

@test "runs bootstrap with the other arguments and a gaia.conf kept in the install dir" {
  publish
  mkdir -p "$DEST"
  cp "$CONF" "$DEST/gaia.conf"
  install --list-steps
  assert_success
  assert_output --partial "running: $DEST/current/bootstrap.sh --config $DEST/gaia.conf --list-steps"
  assert_output --regexp 'preflight +base'
}

@test "invalid options are refused before downloading" {
  install --release 1.0
  assert_failure
  assert_output --partial "invalid --release '1.0'"
  GAIA_REPO='bad repo' install
  assert_failure
  assert_output --partial 'invalid GAIA_REPO'
  refute_called '^curl'
}

@test "--help shows the installer's help without downloading or installing anything" {
  publish
  install --help
  assert_success
  assert_output --partial '--download-only'
  assert_output --partial 'nothing is downloaded or installed'
  refute_output --partial 'downloading'
  refute_called 'curl'
  [[ ! -e $DEST ]]
}

