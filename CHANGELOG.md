# Changelog

## v0.1.0 — unreleased

Initial release.

- Real Linux, two backends behind one `LinuxBackend` protocol, chosen at launch:
  - **microVM** (macOS 14+) — Virtualization.framework, one kernel for the app,
    one vsock connection and pty per tab. Sub-second boot, ~120 MB idle.
  - **Containerization** (macOS 26+) — one lightweight VM per OCI image;
    Alpine, Debian, Ubuntu and Fedora presets.
- Liquid Glass tab strip and window chrome on macOS 26, with an
  `.ultraThinMaterial` fallback down to macOS 14. Glass never composites behind
  live terminal text.
- SwiftTerm rendering, xterm-256color, full scrollback.
- Universal binary (arm64 + x86_64).
- Builds with Command Line Tools only — no Xcode, no SwiftPM, no sudo, at any
  point. `swiftc` is driven directly from the Makefile.
- Ad-hoc signed with `com.apple.security.virtualization` only; the microVM
  backend uses NAT so no restricted entitlement is needed.
- One-line installer with SHA-256 verification, installing to `~/Applications`.
