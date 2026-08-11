# cs-OS

A native macOS terminal front-end for real Linux, styled with macOS 26 Liquid Glass.

Each session is an OCI image running in its own lightweight VM via Apple's
[Containerization](https://github.com/apple/containerization) framework. No Docker
daemon, no Electron, no `.xcodeproj`.

## Install

```sh
curl -fsSL https://chopstickshq.com/cs-os.sh | sh
```

No sudo, no Xcode, no toolchain. Prebuilt app, checksum-verified.

## Build

Releases are built in CI (`.github/workflows/release.yml`) on a GitHub `macos-26`
runner, where Xcode is preinstalled and its license is already accepted. Tag and
push; the artifact publishes itself:

```sh
git tag v0.1.0 && git push --tags
```

To build locally instead, you need Xcode 26 with its license accepted
(`sudo xcodebuild -license accept` — one time, interactive), then:

```sh
make assets   # fetch kernel + initfs (slow, cached)
make          # compile + bundle dist/cs-OS.app
make run
```

### Bootstrapping the initfs

This is the one step that cannot run in CI. The guest init (`vminitd`) is a static
Swift binary compiled *inside a Linux container*, which needs nested
virtualization — GitHub's macOS runners do not have it.

So it gets built **once**, on a real Apple silicon Mac with the
[`container`](https://github.com/apple/container) CLI installed:

```sh
make assets                       # produces .build/assets/initfs.ext4
gh release create initfs-v1 .build/assets/initfs.ext4
shasum -a 256 .build/assets/initfs.ext4
```

Then set two repo variables so CI can fetch it:

| Variable | Value |
|---|---|
| `CSOS_INITFS_URL` | download URL of the released `initfs.ext4` |
| `CSOS_INITFS_SHA256` | its SHA-256 |

`scripts/fetch-assets.sh` honours `CSOS_INITFS_URL` and skips the container build
entirely when it is set. It only needs redoing when the Containerization version
is bumped.

### Build-host dependencies

| Dependency | Needed for | Notes |
|---|---|---|
| Xcode 26 | Swift 6.2 toolchain | CI runner provides it |
| [`container`](https://github.com/apple/container) CLI | initfs bootstrap only | one-time; **end users never need it** |
| `curl`, `tar`, `unzip` | asset fetch | system-provided |
| `e2fsck` / `resize2fs` | shrinking the initfs | optional; skipped if absent |

## Layout

```
Package.swift              SwiftPM manifest (no Xcode project)
Makefile                   build → bundle → sign → archive → release
Sources/csos/
  CSOSApp.swift            @main App entry, window + commands
  Backend/
    LinuxBackend.swift     protocol seam — swap Containerization for anything
    ContainerBackend.swift Containerization impl, PTY plumbing
  Terminal/
    TerminalPane.swift     SwiftTerm bridge (opaque, no glass — deliberate)
  UI/
    GlassChrome.swift      Liquid Glass tab strip + toolbar
    RootView.swift         layout
    Theme.swift            colors, font, metrics
  Model/Session.swift      tabs and their lifecycle
Resources/
  Info.plist               templated with VERSION/BUILD at bundle time
  csos.entitlements        virtualization + vmnet
scripts/fetch-assets.sh    kernel, initfs, font
dist/cs-os.sh              the curl | sh installer (no sudo, ever)
site/cs-os/index.html      chopstickshq.com project page
.github/workflows/         CI build + release
```

## Design notes

**Glass never touches the text grid.** `TerminalPane` is explicitly opaque.
Translucency behind a surface that repaints on every keystroke forces the
compositor to re-blur continuously; that is how a good-looking terminal ends up
feeling slow. All the Liquid Glass lives in `GlassChrome.swift`, over a static
backdrop the compositor can cache.

**The backend is behind a protocol.** `LinuxBackend` exists so the
Containerization implementation can be replaced with an EFI + Alpine disk-image
backend without the UI noticing.

**Signing is ad-hoc.** cs-OS is distributed only via `curl | sh`. curl does not
set `com.apple.quarantine`, so Gatekeeper does not require notarization. A copy
downloaded through a browser *will* be blocked — that is a deliberate trade.

## Release

```sh
make archive VERSION=0.1.0   # dist/cs-os-v0.1.0-arm64.zip + .sha256 + latest.json
make release VERSION=0.1.0   # uploads via gh
```

Binaries live on GitHub Releases; the website only hosts two static files:

| Path on chopstickshq.com | Source |
|---|---|
| `/cs-os.sh` | `dist/cs-os.sh` |
| `/cs-os/` | `site/cs-os/index.html` |

The installer resolves `latest.json` from the GitHub release, so cutting a
release needs no website deploy at all.
