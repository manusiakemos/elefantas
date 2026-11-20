// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PGKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PGKit", targets: ["PGKit"]),
    ],
    targets: [
        // Built by scripts/build-libpq.sh (static libpq + OpenSSL, universal).
        .binaryTarget(name: "CLibPQ", path: "Vendor/CLibPQ.xcframework"),
        .target(name: "PGKit", dependencies: ["CLibPQ"]),
        .testTarget(name: "PGKitTests", dependencies: ["PGKit"]),
    ]
)
