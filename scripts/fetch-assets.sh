#!/bin/bash
#
# Produces the Linux runtime assets cs-OS ships in its bundle:
#
#   .build/assets/vmlinux    an arm64 kernel with virtio compiled in
#   .build/assets/*.ttf      JetBrains Mono NL
#
# The guest init (vminitd) is NOT built here. Apple publishes it as a public OCI
# image at ghcr.io/apple/containerization/vminit, which the app resolves at
# runtime — so no Linux toolchain, no `container` CLI, and no nested
# virtualization is needed to produce a release. See ContainerBackend.swift.
#
set -euo pipefail

KATA_VERSION="3.17.0"
KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-arm64.tar.xz"
FONT_VERSION="2.304"

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
  # Only one member is needed; extracting everything would unpack ~1 GiB.
  tar -xJf "$tarball" -C "$CACHE" \
      --strip-components=5 \
      'opt/kata/share/kata-containers/vmlinux.container' \
    || die "vmlinux.container not found — Kata may have changed its layout"

  mv "${CACHE}/vmlinux.container" "${ASSETS}/vmlinux"
  log "kernel ready ($(du -h "${ASSETS}/vmlinux" | cut -f1))"
}

# ---------------------------------------------------------------- font

fetch_font() {
  if [ -f "${ASSETS}/JetBrainsMonoNL-Regular.ttf" ]; then
    log "font already present"
    return
  fi
  log "downloading JetBrains Mono NL"
  local zip="${CACHE}/jetbrains-mono.zip"
  [ -f "$zip" ] || curl -fL --progress-bar -o "$zip" \
    "https://github.com/JetBrains/JetBrainsMono/releases/download/v${FONT_VERSION}/JetBrainsMono-${FONT_VERSION}.zip"
  unzip -o -j "$zip" 'fonts/ttf/JetBrainsMonoNL-Regular.ttf' \
                     'fonts/ttf/JetBrainsMonoNL-Bold.ttf' \
                     'fonts/ttf/JetBrainsMonoNL-Italic.ttf' -d "$ASSETS" >/dev/null
  log "font ready"
}

fetch_kernel
fetch_font

log "assets complete:"
du -h "$ASSETS"/* | sed 's/^/    /'
