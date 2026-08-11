#!/bin/bash
# Fetch the prebuilt Linux guest (kernel + initramfs + rootfs) into guest/dist.
#
# These are cross-compiled on Linux in CI and published as release assets.
# Building them on macOS would require a Linux cross-toolchain — i.e. Docker —
# which is exactly the heavyweight privileged dependency cs-OS avoids.
#
# No sudo. Everything lands under the repo.

set -euo pipefail

REPO="${CSOS_GUEST_REPO:-ilikemacos/cs-OS}"
GUEST_TAG="${CSOS_GUEST_TAG:-guest-v0.1.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/guest/dist"
ARTIFACT="csos-guest-${GUEST_TAG#guest-}.tar.gz"
URL="https://github.com/$REPO/releases/download/$GUEST_TAG/$ARTIFACT"

info() { printf '\033[38;5;110m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Already present and complete? Nothing to do.
if [ -f "$DEST/manifest.json" ] && [ -f "$DEST/arm64/kernel" ] && [ -f "$DEST/x86_64/kernel" ]; then
  info "guest image already present in guest/dist (delete it to re-fetch)"
  exit 0
fi

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "downloading $ARTIFACT"
if ! curl -fSL --progress-bar "$URL" -o "$TMP/$ARTIFACT"; then
  die "could not download the guest image.

  $URL

  No guest release has been published yet. Until one exists, build it with
  .github/workflows/guest.yml (a Linux runner), or point this script at your
  own build:

    CSOS_GUEST_REPO=you/your-fork CSOS_GUEST_TAG=guest-v0.1.0 make guest"
fi

info "verifying checksum"
if curl -fsSL "$URL.sha256" -o "$TMP/sum" 2>/dev/null; then
  expected="$(awk '{print $1}' "$TMP/sum")"
  actual="$(shasum -a 256 "$TMP/$ARTIFACT" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || die "checksum mismatch
    expected $expected
    actual   $actual"
else
  die "no checksum published alongside the guest image — refusing to use it."
fi

info "extracting to guest/dist"
tar -xzf "$TMP/$ARTIFACT" -C "$DEST" --strip-components=1

[ -f "$DEST/manifest.json" ] || die "guest archive is missing manifest.json"
for arch in arm64 x86_64; do
  for f in kernel initramfs.cpio.gz rootfs.erofs overlay-seed.ext4; do
    [ -f "$DEST/$arch/$f" ] || die "guest archive is missing $arch/$f"
  done
done

info "guest image ready ($(du -sh "$DEST" | cut -f1))"
