// swift-tools-version: 6.0
import PackageDescription

// NOTE: This manifest is for CI and for machines with a working SwiftPM only.
//
// Stock Command Line Tools cannot build it — CLT 26.5 ships a
// libPackageDescription that exports no Package symbols, so every manifest,
// including `swift package init`'s own template, fails to link. The Makefile
// therefore drives swiftc directly and is the supported local path.
//
// This manifest exists so the Containerization backend (macOS 26+) can still be
// built where SwiftPM works. It defines CSOS_CONTAINERIZATION, which is the
// flag that compiles Sources/csos/Backend/ContainerBackend.swift in.

let package = Package(
    name: "cs-OS",
    platforms: [
        // Containerization itself requires 26; the microVM backend goes to 14.
        // This manifest is the 26+ build, so it declares 26.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "csos", targets: ["csos"])
    ],
    dependencies: [
        // Must stay in lockstep with the vminit OCI image tag the app resolves
        // at runtime (ghcr.io/apple/containerization/vminit:0.33.3) — the
        // host<->guest vsock/gRPC contract is versioned together.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.33.3"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.18.0")
    ],
    targets: [
        .executableTarget(
            name: "csos",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationError", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/csos",
            swiftSettings: [
                .define("CSOS_CONTAINERIZATION")
            ]
        )
    ]
)
