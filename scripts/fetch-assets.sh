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

  # Don't guess at Kata's layout — ask the archive. `vmlinux.container` is a
  # symlink to a versioned image, and glob patterns behave differently between
  # bsdtar and GNU tar, so list the real member names first and extract those.
  log "locating kernel in archive"
  rm -f "${CACHE}"/vmlinux*

  local members=""
  while IFS= read -r line; do
    members="${members}${line}
"
  done < <(tar -tJf "$tarball" | grep -E 'kata-containers/vmlinux[^/]*$' || true)

  [ -n "$members" ] || die "no vmlinux entries in archive — Kata changed its layout"
  printf '%s' "$members" | sed 's/^/      /'

  # shellcheck disable=SC2086
  tar -xJf "$tarball" -C "$CACHE" --strip-components=4 $(printf '%s ' $members) \
    || die "extraction failed"

  # Pick the largest real file — skips the dangling .container symlink.
  local src
  src=$(find "$CACHE" -maxdepth 1 -name 'vmlinux*' -type f -size +1M 2>/dev/null | sort | tail -1)
  [ -n "$src" ] || die "no real kernel file extracted (only symlinks?)"
  log "using $(basename "$src")"

  cp "$src" "${ASSETS}/vmlinux"

  # A zero-byte kernel silently produces an app that cannot boot anything.
  local size
  size=$(wc -c < "${ASSETS}/vmlinux" | tr -d ' ')
  [ "$size" -gt 1000000 ] || die "kernel is only ${size} bytes — extraction failed"

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
