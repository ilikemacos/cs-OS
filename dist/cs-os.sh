#!/bin/sh
#
# cs-OS installer
#   curl -fsSL https://chopstickshq.com/cs-os.sh | sh
#
# Never uses sudo. Never needs Xcode, a compiler, or a toolchain.
# Installs a prebuilt, ad-hoc-signed .app and nothing else.
#
set -eu

REPO="ilikemacos/cs-OS"
APP_NAME="cs-OS.app"
RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"

# --------------------------------------------------------------- output

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM='\033[2m'; C_CYAN='\033[38;5;110m'; C_RED='\033[31m'
  C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_OFF='\033[0m'
else
  C_DIM=''; C_CYAN=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_OFF=''
fi

say()  { printf "${C_CYAN}==>${C_OFF} %s\n" "$1"; }
warn() { printf "${C_YELLOW}warning:${C_OFF} %s\n" "$1" >&2; }
die()  { printf "${C_RED}error:${C_OFF} %s\n" "$1" >&2; exit 1; }

TMP=""
cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM HUP

# --------------------------------------------------------------- preflight

[ "$(uname -s)" = "Darwin" ] || die "cs-OS only runs on macOS (found $(uname -s))."

ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || die "cs-OS requires Apple silicon (found $ARCH).
    It runs Linux in a hardware-virtualized VM, which needs an M-series chip."

MACOS_VER="$(sw_vers -productVersion)"
if [ "$(echo "$MACOS_VER" | cut -d. -f1)" -lt 26 ]; then
  die "cs-OS requires macOS 26 or later (found $MACOS_VER).
    It depends on the Containerization framework introduced in macOS 26."
fi

for tool in curl shasum ditto; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# --------------------------------------------------------------- destination
#
# No sudo, ever. /Applications is writable by admin users on a normal Mac; if it
# isn't, we fall back to ~/Applications rather than asking for a password.

if [ -w "/Applications" ]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="${HOME}/Applications"
  mkdir -p "$INSTALL_DIR" || die "cannot create ${INSTALL_DIR}"
  say "/Applications is not writable — installing to ~/Applications"
fi
TARGET="${INSTALL_DIR}/${APP_NAME}"

# --------------------------------------------------------------- resolve

say "resolving latest release"
MANIFEST="$(curl -fsSL "${RELEASE_BASE}/latest.json" 2>/dev/null)" \
  || die "could not fetch the release manifest.
    Either there is no published release yet, or the network is unavailable.
    Check: https://github.com/${REPO}/releases"

json_field() {
  echo "$MANIFEST" | tr -d '\n' \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

VERSION="$(json_field version)"
ARTIFACT="$(json_field artifact)"
EXPECTED_SHA="$(json_field sha256)"

[ -n "$VERSION" ]      || die "malformed manifest: missing version"
[ -n "$ARTIFACT" ]     || die "malformed manifest: missing artifact"
[ -n "$EXPECTED_SHA" ] || die "malformed manifest: missing sha256"

# --------------------------------------------------------------- existing

if [ -d "$TARGET" ]; then
  CURRENT="$(defaults read "${TARGET}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  if [ "$CURRENT" = "$VERSION" ] && [ "${CSOS_FORCE:-0}" != "1" ]; then
    say "cs-OS v${VERSION} is already installed and up to date."
    printf "${C_DIM}    Reinstall: CSOS_FORCE=1 curl -fsSL https://chopstickshq.com/cs-os.sh | sh${C_OFF}\n"
    exit 0
  fi
  [ "$CURRENT" = "$VERSION" ] || say "upgrading ${CURRENT} -> ${VERSION}"
  pgrep -x csos >/dev/null 2>&1 && die "cs-OS is running. Quit it and re-run this installer."
fi

# --------------------------------------------------------------- download

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csos.XXXXXX")" || die "could not create temp dir"
ZIP="${TMP}/${ARTIFACT}"

say "downloading cs-OS v${VERSION}"
curl -fL --progress-bar -o "$ZIP" "${RELEASE_BASE}/${ARTIFACT}" \
  || die "download failed: ${RELEASE_BASE}/${ARTIFACT}"

say "verifying checksum"
ACTUAL_SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || die "checksum mismatch — refusing to install.
    expected: ${EXPECTED_SHA}
    actual:   ${ACTUAL_SHA}"

# --------------------------------------------------------------- install

say "extracting"
ditto -x -k "$ZIP" "$TMP" || die "extraction failed (corrupt archive?)"
[ -d "${TMP}/${APP_NAME}" ] || die "archive did not contain ${APP_NAME}"

xattr -dr com.apple.quarantine "${TMP}/${APP_NAME}" 2>/dev/null || true

say "installing to ${INSTALL_DIR}"
# Stage the swap so a failure never leaves a half-installed bundle behind.
if [ -d "$TARGET" ]; then
  mv "$TARGET" "${TMP}/previous-${APP_NAME}" \
    || die "could not replace ${TARGET} — check permissions."
fi
if ! ditto "${TMP}/${APP_NAME}" "$TARGET"; then
  [ -d "${TMP}/previous-${APP_NAME}" ] && mv "${TMP}/previous-${APP_NAME}" "$TARGET"
  die "install failed; previous version restored."
fi

codesign --verify --deep --strict "$TARGET" >/dev/null 2>&1 || warn \
  "signature did not verify. cs-OS is ad-hoc signed so this can be benign,
    but if it refuses to launch run: xattr -cr \"$TARGET\""

printf "\n${C_GREEN}cs-OS v%s installed${C_OFF} -> %s\n\n" "$VERSION" "$TARGET"
printf "  Launch:  ${C_CYAN}open -a cs-OS${C_OFF}\n"
printf "  First run pulls Alpine (~3.5 MB) and boots in about a second.\n\n"
printf "${C_DIM}  Uninstall: rm -rf \"%s\" ~/Library/Application\\ Support/cs-OS${C_OFF}\n\n" "$TARGET"
