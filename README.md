# cs-OS

A native macOS terminal front-end for real Linux, styled with macOS 26 Liquid Glass.

Not an emulator and not a shell wrapper: a real Linux kernel with a real
userland. No Docker daemon, no Electron, no `.xcodeproj`.

## Install

```sh
curl -fsSL https://chopstickshq.com/cs0s/install.sh | sh
```

No sudo, no Xcode, no toolchain. Prebuilt app, checksum-verified, installed to
`~/Applications`.

## Two backends, one protocol

Both conform to `LinuxBackend`, so the UI never branches on which is running.
`BackendFactory` picks at launch:

| | microVM | Containerization |
|---|---|---|
| macOS | 14+ | 26+ |
| Guest | bundled Alpine + musl | any OCI image |
| Model | one kernel, one vsock connection per tab | one lightweight VM per tab |
| Idle RAM | ~120 MB total | ~200 MB per session |
| Boot | sub-second | 1–2 s |

The microVM backend is what keeps cs-OS installable on 4 GB-class machines that
can never run macOS 26. It uses `VZNATNetworkDeviceAttachment`, which needs no
restricted entitlement and no root.

## Build — no Xcode, no sudo

**Xcode is not required and is never invoked.** Every build command forces
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`, so the Command Line Tools
toolchain is used even on machines where Xcode is installed but its licence has
never been accepted (accepting it would need `sudo`).

Requirements: Command Line Tools (`xcode-select --install`), `curl`, `git`.

```sh
make deps     # vendor SwiftTerm at a pinned tag
make guest    # fetch the prebuilt kernel + rootfs
make          # compile + bundle dist/cs-OS.app
make run
```

### Why not SwiftPM?

SwiftPM does not work on stock Command Line Tools. CLT 26.5 ships a
`libPackageDescription.dylib` that exports **zero** `Package` symbols, so every
manifest fails to link — including the template `swift package init` generates
itself:

```
Undefined symbols for architecture arm64:
  "PackageDescription.Package.__allocating_init(...)"
```

So the Makefile drives `swiftc` directly and vendors SwiftTerm as a static
module. This removes the last reason anyone would need Xcode installed.

`Package.swift` is retained **only** for CI and for machines with a working
SwiftPM, because the Containerization backend is an SPM dependency. It defines
`CSOS_CONTAINERIZATION`, the flag that compiles
`Sources/csos/Backend/ContainerBackend.swift` in. The local `swiftc` path omits
that file and builds the microVM backend alone.

### The guest image

The kernel and rootfs are cross-compiled on Linux in CI and published as release
assets; `make guest` downloads them. Building them on macOS would mean a Linux
cross-toolchain, i.e. Docker, i.e. exactly the heavyweight privileged dependency
this project exists to avoid.

The guest agent (`guest/src/paned.c`, ~40 KB static against musl) runs as PID 1,
listens on vsock, and gives each tab its own pty and `/bin/sh`.

### Signing

`make bundle` ad-hoc signs with `Resources/csos-microvm.entitlements`, which
claims only `com.apple.security.virtualization`. That entitlement *is* honoured
for ad-hoc signatures, which is what lets cs-OS run a VM with no Developer ID.

`com.apple.vm.networking` is deliberately excluded from that file: it is a
restricted entitlement Apple grants by application only, and an ad-hoc binary
claiming it can fail to launch outright. `Resources/csos.entitlements` keeps it
for a future Developer ID build.

## Licensing

The Swift app is ours. The bundled kernel and busybox are GPL-2.0, so releases
ship a `SOURCES.md` with the exact build recipe and kernel config. They are
separate programs merely aggregated in the bundle, so they do not affect the
app's own licence.
