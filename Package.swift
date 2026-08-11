// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "csos",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "csos", targets: ["csos"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.33.3"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "csos",
            dependencies: [
                // ContainerizationError ships inside the Containerization
                // library product, so it must not be listed separately.
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/csos",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ]
        )
    ]
)
