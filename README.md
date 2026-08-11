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

### The guest init

cs-OS does not build or bundle the Linux guest init. Apple publishes `vminitd` as
a public OCI image, and the app resolves it at runtime:

```
ghcr.io/apple/containerization/vminit:0.33.3
```

It is pulled on first launch and cached in the image store, so later launches are
offline. **The tag must track the Containerization version pinned in
`Package.swift`** — the host↔guest vsock/gRPC contract is versioned together, so
bump both or neither.

This is why the build needs no Linux toolchain, no
[`container`](https://github.com/apple/container) CLI, and no nested
virtualization: `make assets` is just a kernel download.

### Build-host dependencies

| Dependency | Needed for | Notes |
|---|---|---|
| Xcode 26 | Swift 6.2 toolchain | CI runner provides it |
| `curl`, `tar`, `unzip` | asset fetch | system-provided |

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
