// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhoneBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "PhoneBridgeCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]),
        .executableTarget(
            name: "PhoneBridge",
            dependencies: ["PhoneBridgeCore"]),
        .testTarget(
            name: "PhoneBridgeCoreTests",
            dependencies: ["PhoneBridgeCore"]),
    ]
)
