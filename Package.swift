// swift-tools-version: 6.3
// Package.swift: Swift Package Manager manifest for the swift-crud executable target and its test target, with dependencies on Blackbird (SQLite ORM), swift-nio, and swift-nio-ssl.

import PackageDescription

let package = Package(
    name: "swift-crud",
    platforms: [
        .macOS(.v12),
        .custom("linux", versionString: "1.0"),
    ],

    dependencies: [
        .package(url: "https://github.com/bdombro/Blackbird-fast", from: "1.0.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.55.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    ],
    targets: [
        .executableTarget(
            name: "swift-crud",
            dependencies: [
                .product(name: "Blackbird", package: "Blackbird-fast"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "swift-crudTests",
            dependencies: [
                .target(name: "swift-crud"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
