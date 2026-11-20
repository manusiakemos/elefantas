// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ElefantasCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ElefantasCore", targets: ["ElefantasCore"]),
    ],
    dependencies: [
        .package(path: "../PGKit"),
    ],
    targets: [
        .target(name: "ElefantasCore", dependencies: ["PGKit"]),
        .testTarget(name: "ElefantasCoreTests", dependencies: ["ElefantasCore"]),
    ]
)
