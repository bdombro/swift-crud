// swift-tools-version: 6.3
// Package.swift: Swift Package Manager manifest for the swift-crud executable target and its test target, with dependencies on Blackbird (SQLite ORM), swift-nio, and swift-nio-transport-services.

import PackageDescription

let package = Package(
    name: "swift-crud",
    platforms: [
        .macOS(.v12)
    ],

    dependencies: [
        .package(url: "https://github.com/bdombro/Blackbird-fast", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.55.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "swift-crud",
            dependencies: [
                .product(name: "Blackbird", package: "Blackbird-fast"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        ),
        .testTarget(
            name: "swift-crudTests",
            dependencies: [
                .target(name: "swift-crud")
            ]
        ),
    ]
)
