#!/usr/bin/env bash
# Gaia installer: downloads a Gaia release, verifies it (SHA-256 and, when a release key is
# embedded, its Ed25519 signature) BEFORE running anything, and starts bootstrap.sh.
#
#   curl -fsSL https://github.com/Black-Ghost-Corp/Gaia-Bootstrapper/releases/latest/download/install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --modules docker --admin-user alice --yes
#
# Installer options (everything else is passed to bootstrap.sh, see bootstrap.sh --help):
#   --release vX.Y.Z   install this release instead of the latest one
#   --dir DIR          installation directory (default /opt/gaia)
#   --download-only    install the release but do not run it
#
# Environment: GAIA_REPO (owner/name on GitHub), GAIA_RELEASE_PUBKEY, GAIA_INSTALL_DIR.
#
# Copyright 2026 The Gaia Authors. Licensed under the Apache License, Version 2.0.
set -Eeuo pipefail
umask 022

# Filled in at release time (scripts/release.sh installer). Do not edit by hand.
EMBEDDED_PUBKEY=""

REPO=${GAIA_REPO:-Black-Ghost-Corp/Gaia-Bootstrapper}
PUBKEY=${GAIA_RELEASE_PUBKEY:-$EMBEDDED_PUBKEY}
DEST=${GAIA_INSTALL_DIR:-/opt/gaia}
SIGNATURE_FORMAT="gaia-release/1"
ED25519_PUBLIC_DER_PREFIX=302a300506032b6570032100

TAG=""
DOWNLOAD_ONLY=0
TMP=""
BOOTSTRAP_ARGS=()

die() {
  echo "[gaia-install] error: $*" >&2
  exit 1
}
info() { echo "[gaia-install] $*" >&2; }

cleanup() { [[ -z $TMP || ! -d $TMP ]] || rm -rf "$TMP"; }
trap cleanup EXIT

parse_args() {
  while (($#)); do
    case $1 in
      --release) TAG=${2:?--release needs a tag (vX.Y.Z)}; shift ;;
      --release=*) TAG=${1#*=} ;;
      --dir) DEST=${2:?--dir needs a directory}; shift ;;
      --dir=*) DEST=${1#*=} ;;
      --download-only) DOWNLOAD_ONLY=1 ;;
      --) shift; BOOTSTRAP_ARGS+=("$@"); break ;;
      *) BOOTSTRAP_ARGS+=("$1") ;;
    esac
    shift
  done
  [[ -z $TAG || $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid --release '$TAG' (expected vX.Y.Z)"
  [[ $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid GAIA_REPO '$REPO' (owner/name)"
  [[ -z $PUBKEY || $PUBKEY =~ ^[0-9a-f]{64}$ ]] || die "invalid release public key (64 lowercase hex characters)"
  [[ $DEST =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid --dir '$DEST' (absolute path)"
}

install_dependencies() {
  local -a missing=() cmds=(curl tar gzip sha256sum)
  local c
  [[ -n $PUBKEY ]] && cmds+=(openssl xxd)
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 && continue
    case $c in
      sha256sum) missing+=(coreutils) ;;
      *) missing+=("$c") ;;
    esac
  done
  ((${#missing[@]})) || return 0
  command -v apt-get >/dev/null 2>&1 || die "missing ${missing[*]} and no apt-get to install it"
  info "installing ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 --max-time 600 --retry 3 -o "$2" "$1" 2>/dev/null ||
    die "download failed: $1"
}

# Value of a string field in version.json (pretty-printed by jq at release time; no jq needed here).
json_field() {
  sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$2" | head -n1
}

resolve_tag() {
  [[ -z $TAG ]] || return 0
  # https://github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>.
  local url
  url=$(curl -fsSL --proto '=https' --max-time 60 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null) ||
    die "could not find the latest release of $REPO on GitHub"
  TAG=${url##*/}
  [[ $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine the latest release (got '$TAG')"
}

download_and_verify() {
  local base package version signature dir=$TMP/release
  mkdir -p "$dir"
  base="https://github.com/$REPO/releases/download/$TAG"
  package="gaia-$TAG.tar.gz"
  info "downloading Gaia $TAG from GitHub ($REPO)"
  fetch "$base/$package" "$dir/$package"
  fetch "$base/SHA256SUMS" "$dir/SHA256SUMS"
  fetch "$base/version.json" "$dir/version.json"

  grep -Eq "^[0-9a-f]{64}  $package\$" "$dir/SHA256SUMS" || die "SHA256SUMS does not list $package"
  (cd "$dir" && sha256sum --check --strict --status SHA256SUMS) || die "the package does NOT match SHA256SUMS; refusing"
  version=$(json_field version "$dir/version.json")
  [[ $(json_field tag "$dir/version.json") == "$TAG" && "v$version" == "$TAG" ]] || die "version.json is not from $TAG"

  if [[ -n $PUBKEY ]]; then
    signature=$(json_field signature "$dir/version.json")
    [[ $signature =~ ^[0-9a-f]{128}$ ]] || die "release $TAG is not signed; refusing (this installer expects signed releases)"
    { printf '%s\n%s\n' "$SIGNATURE_FORMAT" "$version"; cat "$dir/SHA256SUMS"; } >"$dir/message"
    printf '%s' "$signature" | xxd -r -p >"$dir/signature"
    printf '%s' "$ED25519_PUBLIC_DER_PREFIX$PUBKEY" | xxd -r -p | openssl pkey -pubin -inform DER -out "$dir/public.pem" 2>/dev/null ||
      die "invalid release public key"
    openssl pkeyutl -verify -pubin -inkey "$dir/public.pem" -rawin -in "$dir/message" -sigfile "$dir/signature" >/dev/null 2>&1 ||
      die "the signature of release $TAG does NOT match the release key; refusing"
    info "package and signature verified"
  else
    info "warning: no release public key embedded; only the SHA-256 sums were checked (they come from the same source as the package)"
  fi
  PACKAGE=$dir/$package
  VERSION=$version
}

install_release() {
  local target=$DEST/releases/$VERSION extracted=$TMP/extracted
  mkdir -p "$extracted" "$DEST/releases"
  chmod 755 "$DEST" "$DEST/releases"
  tar -xzf "$PACKAGE" -C "$extracted" --no-same-owner
  [[ -f $extracted/gaia-$TAG/bootstrap.sh ]] || die "package without gaia-$TAG/bootstrap.sh"
  rm -rf "$target"
  mv "$extracted/gaia-$TAG" "$target"
  chmod -R go-w "$target"
  ln -sfn "$target" "$DEST/current"
  info "Gaia $TAG installed in $target ($DEST/current)"
}

run_gaia() {
  local arg has_config=0
  for arg in "${BOOTSTRAP_ARGS[@]}"; do
    [[ $arg == --config || $arg == --config=* ]] && has_config=1
  done
  # A gaia.conf kept in the installation directory survives upgrades.
  if ((!has_config)) && [[ -f $DEST/gaia.conf ]]; then
    BOOTSTRAP_ARGS=(--config "$DEST/gaia.conf" "${BOOTSTRAP_ARGS[@]}")
  fi
  info "running: $DEST/current/bootstrap.sh ${BOOTSTRAP_ARGS[*]}"
  exec bash "$DEST/current/bootstrap.sh" "${BOOTSTRAP_ARGS[@]}"
}

main() {
  parse_args "$@"
  [[ $(id -u) == 0 ]] || die "run as root: curl -fsSL <url>/install.sh | sudo bash"
  install_dependencies
  TMP=$(mktemp -d /tmp/gaia-install.XXXXXX)
  resolve_tag
  download_and_verify
  install_release
  if ((DOWNLOAD_ONLY)); then
    info "done; run it with: sudo $DEST/current/bootstrap.sh --help"
    exit 0
  fi
  cleanup
  TMP=""
  run_gaia
}

main "$@"
