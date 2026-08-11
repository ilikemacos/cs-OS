#!/bin/sh
# cs-OS installer — https://chopstickshq.com/cs0s/
#
#   curl -fsSL https://chopstickshq.com/cs0s/install.sh | sh
#
# Never uses sudo. Never needs Xcode, a compiler, or a toolchain.
# Installs to ~/Applications, which is owned by you.

set -eu

REPO="ilikemacos/cs-OS"
APP_NAME="cs-OS.app"
INSTALL_DIR="${CSOS_PREFIX:-$HOME/Applications}"
MIN_MACOS_MAJOR=14
MIN_RAM_BYTES=4294967296   # 4 GiB, the stated minimum spec

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '\033[38;5;110m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { red "error: $*"; exit 1; }

cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ guards

# Running as root would create root-owned files in a user's home directory —
# the exact breakage this project exists to avoid.
if [ "$(id -u)" = "0" ]; then
  die "do not run this installer as root or with sudo.
    cs-OS installs entirely under your home directory."
fi

[ "$(uname -s)" = "Darwin" ] || die "cs-OS is macOS only (found $(uname -s))."

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *) die "unsupported architecture: $ARCH (need arm64 or x86_64)." ;;
esac

MACOS_VER="$(sw_vers -productVersion)"
MACOS_MAJOR="$(echo "$MACOS_VER" | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
  die "cs-OS requires macOS $MIN_MACOS_MAJOR or later (found $MACOS_VER)."
fi
if [ "$MACOS_MAJOR" -lt 26 ]; then
  info "macOS $MACOS_VER: using the bundled microVM backend."
  info "Liquid Glass effects need macOS 26; you'll get the material fallback."
fi

RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
if [ "$RAM_BYTES" -gt 0 ] && [ "$RAM_BYTES" -lt "$MIN_RAM_BYTES" ]; then
  die "cs-OS needs at least 4GB of RAM (found $((RAM_BYTES / 1024 / 1024))MB)."
fi

for tool in curl shasum tar mkdir; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# Virtualization.framework is unavailable inside a VM on Intel, and cs-OS is a
# VM host — fail here rather than at a confusing first launch.
if [ "$ARCH" = "x86_64" ] && sysctl -n machdep.cpu.features 2>/dev/null | grep -q VMM; then
  die "cs-OS cannot run inside a virtual machine (nested virtualization unavailable)."
fi

# ------------------------------------------------------------------ resolve

info "Resolving latest release…"
API="https://api.github.com/repos/$REPO/releases/latest"
META="$(curl -fsSL "$API" 2>/dev/null)" || die "could not reach GitHub to resolve the latest release."

VERSION="$(printf '%s' "$META" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
[ -n "$VERSION" ] || die "could not determine the latest version."

ARTIFACT="cs-OS-${VERSION}-macos-universal.tar.gz"
URL="https://github.com/$REPO/releases/download/v${VERSION}/${ARTIFACT}"
SUM_URL="${URL}.sha256"

# ------------------------------------------------------------------ existing

DEST="$INSTALL_DIR/$APP_NAME"
if [ -e "$DEST" ]; then
  EXISTING="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
  if [ "$EXISTING" = "$VERSION" ]; then
    info "cs-OS $VERSION is already installed at $DEST"
    info "Reinstalling anyway."
  else
    info "Upgrading cs-OS $EXISTING -> $VERSION"
  fi
  if [ ! -w "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR is not writable by you.
    Set a different location: CSOS_PREFIX=\"\$HOME/bin\" and re-run."
  fi
fi

mkdir -p "$INSTALL_DIR" 2>/dev/null || die "could not create $INSTALL_DIR"
[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR is not writable by you."

# ------------------------------------------------------------------ download

TMP="$(mktemp -d)"
info "Downloading cs-OS $VERSION ($ARCH)…"
curl -fSL --progress-bar "$URL" -o "$TMP/$ARTIFACT" \
  || die "download failed: $URL"

info "Verifying checksum…"
EXPECTED="$(curl -fsSL "$SUM_URL" 2>/dev/null | awk '{print $1}')" \
  || die "could not fetch the checksum file."
[ -n "$EXPECTED" ] || die "checksum file was empty."

ACTUAL="$(shasum -a 256 "$TMP/$ARTIFACT" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  die "checksum mismatch — refusing to install.
    expected $EXPECTED
    actual   $ACTUAL"
fi

# ------------------------------------------------------------------ install

info "Installing to $DEST…"
tar -xzf "$TMP/$ARTIFACT" -C "$TMP" || die "could not extract the archive."
[ -d "$TMP/$APP_NAME" ] || die "archive did not contain $APP_NAME."

# Replace atomically-ish: move the old one aside, then swap it back on failure.
if [ -e "$DEST" ]; then
  rm -rf "$DEST.old"
  mv "$DEST" "$DEST.old" || die "could not replace the existing install."
fi

if ! mv "$TMP/$APP_NAME" "$DEST"; then
  [ -e "$DEST.old" ] && mv "$DEST.old" "$DEST"
  die "could not move the app into $INSTALL_DIR."
fi
rm -rf "$DEST.old"

# curl does not set com.apple.quarantine (only LaunchServices-aware apps like
# browsers do), so this is belt-and-braces for the download-in-Safari path.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# The ad-hoc signature carries the virtualization entitlement. If it did not
# survive the copy, the VM cannot start — surface that now, not on first boot.
if ! codesign --verify "$DEST" >/dev/null 2>&1; then
  warn "the app's code signature did not verify."
  warn "cs-OS may fail to start its virtual machine."
fi

info "Installed cs-OS $VERSION to $DEST"
printf '\n  Launch it:  open -a "%s"\n\n' "$DEST"

# cs-OS is ad-hoc signed, not notarised. Launching from Finder or `open` is
# fine because nothing set a quarantine flag; say so plainly rather than
# claiming the install is invisible to Gatekeeper.
cat <<'EOF'
  Note: cs-OS is ad-hoc signed rather than notarised by Apple.
  Installed this way it launches normally. If you instead download
  the .tar.gz in a browser, macOS will quarantine it and show
  "cannot be opened because the developer cannot be verified" —
  right-click the app and choose Open, once.

EOF
