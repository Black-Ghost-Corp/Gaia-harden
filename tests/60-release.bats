#!/usr/bin/env bats
# scripts/release.sh: version vs tag, reproducible package, Ed25519 signature, installer.

load test_helper

REL="$BATS_TEST_DIRNAME/../scripts/release.sh"

setup_extra() {
  VERSION=$(sed -n 's/^GAIA_VERSION="\(.*\)"$/\1/p' "$REPO/lib/runner.sh")
  TAG="v$VERSION"
  OUT=$BATS_TEST_TMPDIR/dist
  export SOURCE_DATE_EPOCH=1700000000 GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
  unset GAIA_RELEASE_PUBKEY GAIA_RELEASE_SIGNING_KEY
}

# Test Ed25519 pair: PRIVATE (PKCS#8 DER base64) and PUBLIC (64 hex).
make_keys() {
  local d=$BATS_TEST_TMPDIR/keys
  mkdir -p "$d"
  openssl genpkey -algorithm ed25519 -outform DER -out "$d/${1:-a}.der" 2>/dev/null
  PRIVATE=$(base64 -w0 "$d/${1:-a}.der")
  PUBLIC=$(openssl pkey -inform DER -in "$d/${1:-a}.der" -pubout -outform DER | tail -c 32 | xxd -p -c 64)
}

package() { run bash "$REL" package "$TAG" "$OUT"; }

@test "version: a tag matching GAIA_VERSION passes" {
  run bash "$REL" version "$TAG"
  assert_success
  assert_output --partial "matches tag $TAG"
}

@test "version: a different tag is refused, saying what to align" {
  run bash "$REL" version v99.0.0
  assert_failure
  assert_output --partial "does not match GAIA_VERSION=$VERSION"
}

@test "version: a tag outside vX.Y.Z is refused" {
  run bash "$REL" version 1.2.3
  assert_failure
  assert_output --partial 'is not in the vX.Y.Z format'
}

@test "package: tar.gz, SHA256SUMS and a consistent version.json" {
  package
  assert_success
  run ls "$OUT"
  assert_output "SHA256SUMS
gaia-$TAG.tar.gz
version.json"
  run bash -c "cd '$OUT' && sha256sum --check --strict SHA256SUMS"
  assert_success
  run jq -r '[.version, .tag, .commit, .files[0].name, (.files[0].sha256 | length), (.files[0].size > 0)] | join(" ")' "$OUT/version.json"
  assert_output "$VERSION $TAG $GITHUB_SHA gaia-$TAG.tar.gz 64 true"
}

@test "package: only what runs on the server, under gaia-<tag>/, owner 0, executable bootstrap" {
  package
  assert_success
  run tar -tzf "$OUT/gaia-$TAG.tar.gz"
  assert_line "gaia-$TAG/bootstrap.sh"
  assert_line "gaia-$TAG/lib/runner.sh"
  assert_line "gaia-$TAG/lib/modules/10-docker.sh"
  assert_line "gaia-$TAG/gaia.conf.example"
  assert_line "gaia-$TAG/README.md"
  assert_line "gaia-$TAG/README.en.md"
  assert_line "gaia-$TAG/LICENSE"
  refute_output --regexp '(^|/)(tests|scripts|\.github)/'
  refute_line "gaia-$TAG/install.sh"
  refute_line "gaia-$TAG/gaia.conf"
  run bash -c "tar -tvzf '$OUT/gaia-$TAG.tar.gz' | grep ' gaia-$TAG/bootstrap.sh\$'"
  assert_output --regexp '^-rwxr-xr-x 0/0 '
}

@test "package: reproducible (same tree and date = same bytes)" {
  package
  local h1
  h1=$(sha256sum "$OUT/gaia-$TAG.tar.gz" | cut -d' ' -f1)
  OUT=$BATS_TEST_TMPDIR/dist2
  package
  assert_success
  assert_equal "$(sha256sum "$OUT/gaia-$TAG.tar.gz" | cut -d' ' -f1)" "$h1"
}

@test "package: refuses to overwrite an existing package" {
  package
  package
  assert_failure
  assert_output --partial 'already exists'
}

@test "sign: no keys at all goes on unsigned, with a warning" {
  package
  run bash "$REL" sign "$OUT"
  assert_success
  assert_output --partial 'signing not configured'
  run jq -r '.signature // "none"' "$OUT/version.json"
  assert_output none
}

@test "sign: only one of the keys is an error (both or neither)" {
  package
  make_keys
  GAIA_RELEASE_PUBKEY=$PUBLIC run bash "$REL" sign "$OUT"
  assert_failure
  assert_output --partial 'set both or neither'
  GAIA_RELEASE_SIGNING_KEY=$PRIVATE run bash "$REL" sign "$OUT"
  assert_failure
}

@test "sign + verify: 128-hex signature that matches the public key" {
  package
  make_keys
  GAIA_RELEASE_PUBKEY=$PUBLIC GAIA_RELEASE_SIGNING_KEY=$PRIVATE run bash "$REL" sign "$OUT"
  assert_success
  assert_output --partial 'manifest signed'
  run jq -r .signature "$OUT/version.json"
  assert_output --regexp '^[0-9a-f]{128}$'
  run bash "$REL" verify "$OUT" "$PUBLIC"
  assert_success
  assert_output --partial 'signature ok'
}

@test "sign: mismatched pair (public key of another key) fails before publishing" {
  package
  make_keys a
  local private=$PRIVATE
  make_keys b
  GAIA_RELEASE_PUBKEY=$PUBLIC GAIA_RELEASE_SIGNING_KEY=$private run bash "$REL" sign "$OUT"
  assert_failure
  assert_output --partial 'does NOT match'
}

@test "verify: a tampered package is refused" {
  package
  make_keys
  GAIA_RELEASE_PUBKEY=$PUBLIC GAIA_RELEASE_SIGNING_KEY=$PRIVATE bash "$REL" sign "$OUT"
  printf 'x' >>"$OUT/gaia-$TAG.tar.gz"
  run bash "$REL" verify "$OUT" "$PUBLIC"
  assert_failure
  assert_output --partial 'SHA256SUMS does not match'
}

@test "verify: SHA256SUMS replaced together with the package fails the signature" {
  package
  make_keys
  GAIA_RELEASE_PUBKEY=$PUBLIC GAIA_RELEASE_SIGNING_KEY=$PRIVATE bash "$REL" sign "$OUT"
  printf 'x' >>"$OUT/gaia-$TAG.tar.gz"
  (cd "$OUT" && sha256sum "gaia-$TAG.tar.gz" >SHA256SUMS)
  run bash "$REL" verify "$OUT" "$PUBLIC"
  assert_failure
  assert_output --partial 'does NOT match'
}

@test "installer: embeds the public key and publishes its sha256" {
  make_keys
  GAIA_RELEASE_PUBKEY=$PUBLIC run bash "$REL" installer "$OUT"
  assert_success
  run grep '^EMBEDDED_PUBKEY=' "$OUT/install.sh"
  assert_output "EMBEDDED_PUBKEY=\"$PUBLIC\""
  run bash -c "cd '$OUT' && sha256sum --check --strict install.sh.sha256"
  assert_success
}

@test "installer: without a key it is copied as is, with a warning" {
  run bash "$REL" installer "$OUT"
  assert_success
  assert_output --partial 'will only check SHA-256'
  run grep '^EMBEDDED_PUBKEY=' "$OUT/install.sh"
  assert_output 'EMBEDDED_PUBKEY=""'
}
