#!/bin/bash
#
# Produces the two Linux runtime assets cs-OS ships in its bundle:
#
#   .build/assets/vmlinux       an arm64 kernel with virtio compiled in
#   .build/assets/initfs.ext4   ext4 image containing vminitd (the guest init)
#
# The kernel is lifted out of the Kata Containers static release. The initfs
# has to be *built*, because vminitd is a static Swift binary compiled inside a
# Linux container — that step needs Apple's `container` CLI on the build host.
# It is a build-host dependency only; end users never need it.
#
set -euo pipefail

KATA_VERSION="3.17.0"
CZ_VERSION="0.33.3"
KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-arm64.tar.xz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="${ROOT}/.build/assets"
CACHE="${ROOT}/.build/cache"
mkdir -p "$ASSETS" "$CACHE"

log() { printf '\033[38;5;110m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- kernel

fetch_kernel() {
  if [ -f "${ASSETS}/vmlinux" ]; then
    log "kernel already present ($(du -h "${ASSETS}/vmlinux" | cut -f1))"
    return
  fi

  local tarball="${CACHE}/kata-static-${KATA_VERSION}-arm64.tar.xz"
  if [ ! -f "$tarball" ]; then
    log "downloading Kata ${KATA_VERSION} static package (~277 MiB)"
    curl -fL --progress-bar -o "${tarball}.part" "$KATA_URL"
    mv "${tarball}.part" "$tarball"
  fi

  log "extracting vmlinux.container"
  # Only one member is needed; --wildcards keeps us from unpacking ~1 GiB.
  tar -xJf "$tarball" -C "$CACHE" \
      --strip-components=5 \
      'opt/kata/share/kata-containers/vmlinux.container' \
    || die "vmlinux.container not found — Kata may have changed its layout"

  mv "${CACHE}/vmlinux.container" "${ASSETS}/vmlinux"
  log "kernel ready ($(du -h "${ASSETS}/vmlinux" | cut -f1))"
}

# ---------------------------------------------------------------- initfs

build_initfs() {
  if [ -f "${ASSETS}/initfs.ext4" ]; then
    log "initfs already present ($(du -h "${ASSETS}/initfs.ext4" | cut -f1))"
    return
  fi

  # Fast path. Building the initfs requires running a Linux container, which
  # requires nested virtualization — GitHub's macOS runners do not have it.
  # So CI pulls a prebuilt image instead; it only has to be built once, on a
  # real Mac, and then lives as a release asset.
  if [ -n "${CSOS_INITFS_URL:-}" ]; then
    log "fetching prebuilt initfs"
    curl -fL --progress-bar -o "${ASSETS}/initfs.ext4.part" "$CSOS_INITFS_URL" \
      || die "could not fetch initfs from ${CSOS_INITFS_URL}"
    if [ -n "${CSOS_INITFS_SHA256:-}" ]; then
      actual="$(shasum -a 256 "${ASSETS}/initfs.ext4.part" | cut -d' ' -f1)"
      [ "$actual" = "$CSOS_INITFS_SHA256" ] || die \
        "initfs checksum mismatch (expected ${CSOS_INITFS_SHA256}, got ${actual})"
    fi
    mv "${ASSETS}/initfs.ext4.part" "${ASSETS}/initfs.ext4"
    log "initfs ready ($(du -h "${ASSETS}/initfs.ext4" | cut -f1))"
    return
  fi

  command -v container >/dev/null 2>&1 || die \
    "the 'container' CLI is required to build the guest init (vminitd).
    Install it from https://github.com/apple/container, then re-run.
    This is a build-host dependency only — shipped builds do not need it."

  local src="${CACHE}/containerization-${CZ_VERSION}"
  if [ ! -d "$src" ]; then
    log "fetching containerization ${CZ_VERSION} sources"
    curl -fsSL "https://github.com/apple/containerization/archive/refs/tags/${CZ_VERSION}.tar.gz" \
      | tar xz -C "$CACHE"
    mv "${CACHE}/containerization-${CZ_VERSION}" "$src" 2>/dev/null || true
  fi

  log "building vminitd + initfs (first run builds a Linux dev image; several minutes)"
  make -C "$src" init

  [ -f "${src}/bin/initfs.ext4" ] || die "make init did not produce bin/initfs.ext4"
  cp "${src}/bin/initfs.ext4" "${ASSETS}/initfs.ext4"

  # The image is created as a 512M sparse file but holds only ~30M of vminitd.
  # Shrinking to minimum keeps it from inflating the release tarball.
  if command -v resize2fs >/dev/null 2>&1; then
    log "shrinking initfs to minimum size"
    e2fsck -fy "${ASSETS}/initfs.ext4" >/dev/null 2>&1 || true
    resize2fs -M "${ASSETS}/initfs.ext4" >/dev/null 2>&1 || \
      log "resize2fs failed; keeping full-size image (harmless, just larger)"
  fi

  log "initfs ready ($(du -h "${ASSETS}/initfs.ext4" | cut -f1))"
}

# ---------------------------------------------------------------- font

fetch_font() {
  local out="${ASSETS}/JetBrainsMonoNL-Regular.ttf"
  [ -f "$out" ] && { log "font already present"; return; }
  log "downloading JetBrains Mono NL"
  local zip="${CACHE}/jetbrains-mono.zip"
  [ -f "$zip" ] || curl -fL --progress-bar -o "$zip" \
    "https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip"
  unzip -o -j "$zip" 'fonts/ttf/JetBrainsMonoNL-Regular.ttf' \
                     'fonts/ttf/JetBrainsMonoNL-Bold.ttf' \
                     'fonts/ttf/JetBrainsMonoNL-Italic.ttf' -d "$ASSETS" >/dev/null
  log "font ready"
}

fetch_kernel
build_initfs
fetch_font

log "assets complete:"
du -h "$ASSETS"/* | sed 's/^/    /'
