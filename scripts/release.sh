#!/usr/bin/env bash
# Copyright 2026 Black Ghost Corporation
# SPDX-License-Identifier: Apache-2.0
# Gaia release tooling: package, sign, verify and publish. Called by .github/workflows/release.yml
# (tag vX.Y.Z); every subcommand also works by hand.
#
#   scripts/release.sh version <tag>              checks that the tag matches GAIA_VERSION (lib/runner.sh)
#   scripts/release.sh package <tag> <out>        builds <out>/gaia-<tag>.tar.gz, SHA256SUMS and version.json
#   scripts/release.sh sign <out>                 signs the manifest (optional, see SIGNING below)
#   scripts/release.sh verify <out> <pubkey>      checks the signature with the public key (64 hex)
#   scripts/release.sh installer <out>            copies install.sh (with the public key embedded) + .sha256
#
# PACKAGE: only what runs on the server (bootstrap.sh, lib/, steps.d/, docs/, examples and legal
# files). Tests and development scripts stay out. The tarball is reproducible: the same tree and the
# same SOURCE_DATE_EPOCH (commit date) give the same bytes, so anyone can verify the SHA-256.
#
# SIGNING (Ed25519): the signed message is
#   gaia-release/1\n<version>\n<content of SHA256SUMS>
# and the signature (128 hex) goes into version.json, field "signature". Inputs (environment):
#   GAIA_RELEASE_PUBKEY        public key, 64 hex (public value: repository variable)
#   GAIA_RELEASE_SIGNING_KEY   private key, PKCS#8 DER in base64 (repository secret)
# Both or neither: only one of them is an error. Neither: the release is published unsigned, with a
# warning, and install.sh only checks the SHA-256.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Paths that go into the package, relative to the repository root.
CONTENTS=(bootstrap.sh lib steps.d docs gaia.conf.example README.md README.en.md LICENSE NOTICE CHANGELOG.md)
SIGNATURE_FORMAT="gaia-release/1"
# DER prefix of an Ed25519 public key (SubjectPublicKeyInfo) before the 32 key bytes.
ED25519_PUBLIC_DER_PREFIX=302a300506032b6570032100

die() {
  echo "[release] error: $*" >&2
  exit 1
}
info() { echo "[release] $*"; }

version_from_tag() {
  local tag=$1
  [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "tag '$tag' is not in the vX.Y.Z format"
  printf '%s' "${BASH_REMATCH[1]}"
}

cmd_version() {
  local tag=${1:?usage: release.sh version <tag>} version code
  version=$(version_from_tag "$tag")
  code=$(sed -n 's/^GAIA_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/runner.sh")
  [[ -n $code ]] || die "GAIA_VERSION not found in lib/runner.sh"
  [[ $version == "$code" ]] ||
    die "tag $tag (=> $version) does not match GAIA_VERSION=$code in lib/runner.sh; align them before publishing"
  info "version $version matches tag $tag"
}

sha256() { sha256sum "$1" | cut -d' ' -f1; }

cmd_package() {
  local tag=${1:?usage: release.sh package <tag> <out>} out=${2:?usage: release.sh package <tag> <out>}
  local version name epoch commit p
  version=$(version_from_tag "$tag")
  name="gaia-$tag"
  for p in "${CONTENTS[@]}"; do [[ -e $ROOT/$p ]] || die "$p is missing from the tree"; done
  # Fixed date = commit date: the tarball does not change if rebuilt from the same commit.
  commit=${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}
  epoch=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)}
  mkdir -p "$out"
  out=$(cd "$out" && pwd)
  [[ ! -e $out/$name.tar.gz ]] || die "$out/$name.tar.gz already exists; use an empty directory"

  # --transform puts everything under gaia-<tag>/. Numeric owner 0 and normalized modes: the
  # package does not carry the builder's user or umask. gzip -n: no name or date in the gzip header.
  (cd "$ROOT" && tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go+rX,go-w' --transform="s|^|$name/|" -cf - "${CONTENTS[@]}") |
    gzip -9n >"$out/$name.tar.gz"

  (cd "$out" && sha256sum "$name.tar.gz" >SHA256SUMS)
  jq -n --arg version "$version" --arg tag "$tag" --arg commit "$commit" \
    --arg name "$name.tar.gz" --arg sha "$(sha256 "$out/$name.tar.gz")" \
    --argjson size "$(wc -c <"$out/$name.tar.gz")" \
    '{version: $version, tag: $tag, commit: $commit, files: [{name: $name, sha256: $sha, size: $size}]}' \
    >"$out/version.json"
  info "package $name.tar.gz ($(wc -c <"$out/$name.tar.gz") bytes) in $out"
}

# Signed message: format, version and SHA256SUMS (name and hash of every file).
message() {
  local out=$1 version
  version=$(jq -r .version "$out/version.json")
  printf '%s\n%s\n' "$SIGNATURE_FORMAT" "$version"
  cat "$out/SHA256SUMS"
}

# Turns the public key (64 hex) into PEM for openssl.
public_pem() {
  local hex=$1
  [[ $hex =~ ^[0-9a-f]{64}$ ]] || die "public key has the wrong format (64 lowercase hex characters)"
  printf '%s' "$ED25519_PUBLIC_DER_PREFIX$hex" | xxd -r -p | openssl pkey -pubin -inform DER -outform PEM
}

cmd_verify() {
  local out=${1:?usage: release.sh verify <out> <pubkey>} key=${2:?usage: release.sh verify <out> <pubkey>}
  local tmp signature rc=0
  signature=$(jq -r '.signature // empty' "$out/version.json")
  [[ -n $signature ]] || die "version.json has no signature"
  [[ $signature =~ ^[0-9a-f]{128}$ ]] || die "signature has the wrong format (128 hex)"
  (cd "$out" && sha256sum --check --strict --quiet SHA256SUMS) || die "SHA256SUMS does not match the files"
  tmp=$(mktemp -d)
  public_pem "$key" >"$tmp/public.pem"
  message "$out" >"$tmp/message"
  printf '%s' "$signature" | xxd -r -p >"$tmp/signature"
  openssl pkeyutl -verify -pubin -inkey "$tmp/public.pem" -rawin -in "$tmp/message" -sigfile "$tmp/signature" \
    >/dev/null 2>&1 || rc=$?
  rm -rf "$tmp"
  ((rc == 0)) || die "signature does NOT match the given public key"
  info "signature ok"
}

cmd_sign() {
  local out=${1:?usage: release.sh sign <out>} public private tmp signature
  public=$(printf '%s' "${GAIA_RELEASE_PUBKEY:-}" | tr -d '[:space:]')
  private=$(printf '%s' "${GAIA_RELEASE_SIGNING_KEY:-}" | tr -d '[:space:]')
  if [[ -z $public && -z $private ]]; then
    echo "[release] warning: signing not configured; version.json is published without 'signature'." \
      "Set the GAIA_RELEASE_PUBKEY variable and the GAIA_RELEASE_SIGNING_KEY secret." >&2
    return 0
  fi
  [[ -n $public && -n $private ]] ||
    die "set both or neither: GAIA_RELEASE_PUBKEY (public) and GAIA_RELEASE_SIGNING_KEY (private)"

  tmp=$(mktemp -d)
  # The private key only exists on disk inside this function, in a 700 directory, removed right after.
  chmod 700 "$tmp"
  printf '%s' "$private" | base64 -d >"$tmp/private.der" 2>/dev/null || { rm -rf "$tmp"; die "GAIA_RELEASE_SIGNING_KEY is not valid base64"; }
  message "$out" >"$tmp/message"
  if ! openssl pkeyutl -sign -inkey "$tmp/private.der" -keyform DER -rawin -in "$tmp/message" -out "$tmp/signature" 2>/dev/null; then
    rm -rf "$tmp"
    die "signing failed: GAIA_RELEASE_SIGNING_KEY is not an Ed25519 PKCS#8 key"
  fi
  signature=$(xxd -p -c 256 "$tmp/signature")
  rm -rf "$tmp"
  jq --arg s "$signature" '.signature = $s' "$out/version.json" >"$out/version.json.new"
  mv "$out/version.json.new" "$out/version.json"
  # Verify with the public key before publishing: a mismatched pair is caught here, not on a server.
  cmd_verify "$out" "$public"
  info "manifest signed"
}

# install.sh is published next to the release (not inside the package). When a release key is
# configured, it is embedded so that the installer refuses unsigned or tampered releases.
cmd_installer() {
  local out=${1:?usage: release.sh installer <out>} source=$ROOT/install.sh public
  [[ -f $source ]] || die "install.sh is missing"
  grep -q '^EMBEDDED_PUBKEY=""$' "$source" || die "install.sh has no EMBEDDED_PUBKEY=\"\" line to fill"
  public=$(printf '%s' "${GAIA_RELEASE_PUBKEY:-}" | tr -d '[:space:]')
  mkdir -p "$out"
  if [[ -n $public ]]; then
    [[ $public =~ ^[0-9a-f]{64}$ ]] || die "GAIA_RELEASE_PUBKEY has the wrong format (64 lowercase hex characters)"
    sed "s/^EMBEDDED_PUBKEY=\"\"$/EMBEDDED_PUBKEY=\"$public\"/" "$source" >"$out/install.sh"
  else
    cp "$source" "$out/install.sh"
    echo "[release] warning: no GAIA_RELEASE_PUBKEY; the installer will only check SHA-256 sums" >&2
  fi
  (cd "$out" && sha256sum install.sh >install.sh.sha256)
  info "installer in $out (sha256 $(cut -d' ' -f1 "$out/install.sh.sha256"))"
}

case ${1:-} in
  version) shift; cmd_version "$@" ;;
  package) shift; cmd_package "$@" ;;
  sign) shift; cmd_sign "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  installer) shift; cmd_installer "$@" ;;
  *) echo "usage: $0 version|package|sign|verify|installer ..." >&2; exit 2 ;;
esac
